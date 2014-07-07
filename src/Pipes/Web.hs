{-# LANGUAGE RankNTypes #-}

{-| You can 'deploy' a simple incrementing pipe like this:

> -- deploy.hs
>
> import Pipes
> import qualified Pipes.Prelude as P
> import Pipes.Web
>
> p :: Pipe Int Int IO r
> p = P.map (+ 1)
>
> main = withSocketsDo $ deploy HostAny "8080" p

    This deploys a server that listens on port @8080@ and forks a new thread for
    each installation request:

> $ ./deploy
> ...

    Any program can 'install' the pipe like this:

> -- install.hs
>
> import Pipes
> import Pipes.Safe
> import Pipes.Web
>
> p :: Pipe Int Int (SafeT IO) ()
> p = install "127.0.0.1" "8080"
> 
> main = withSocketsDo $ runSafeT $ runEffect $
>     for (each [1..5] >-> p) (liftIO . print)

    Running this program makes a connection to the server and threads all
    data flowing through the installed pipe to the remote server:

> $ ./install
> 2
> 3
> 4
> 5
> 6
> $

    The server will log all connections to standard output:

> $ ./deploy
> Opening pipe for: 127.0.0.1:53540
> Closing pipe for: 127.0.0.1:53540
> ...

-}

module Pipes.Web (
    -- * Deploy
    deploy,

    -- * Install
    install,
    PaaS(..),
    Managed(..),

    -- * Re-exports
    HostPreference(..),
    HostName,
    ServiceName,
    withSocketsDo
    ) where

import Control.Applicative (Applicative(pure, (<*>)), liftA2)
import Control.Category (Category((.), id))
import Control.Exception (bracket, throwIO)
import Control.Monad.Trans.State.Strict (runStateT)
import qualified Data.ByteString as ByteString
import Data.Word (Word8)
import Lens.Family (view)
import Pipes
import Pipes.Binary (Binary, encode, decode, decoded)
import Pipes.ByteString (nextByte)
import Pipes.Network.TCP
import Prelude hiding ((.), id)

-- TODO: Come up with an exception type for magic byte decoding errors
-- TODO: Remove dead code
-- TODO: Clean up re-exports by just re-exporting a module
-- TODO: All explicit imports

-- Chosen by fair 1d256 rolls

-- Service requesting more input
magicByteNext :: Word8
magicByteNext = 83

-- Service emitting a new value
magicByteYield :: Word8
magicByteYield = 30

-- magicByteReturn :: Word8
-- magicByteReturn = 29

-- | 'deploy' a 'Pipe' that others can 'install'
deploy
    :: (Binary a, Binary b)
    => HostPreference
    -> ServiceName
    -> (Producer a IO () -> Producer b IO ())
    -> IO ()
deploy hostPreference serviceName getter =
    serve hostPreference serviceName $ \(socket, sockAddr) -> do
        let open     = putStrLn $ "Opening pipe for: " ++ show sockAddr
        let close () = putStrLn $ "Closing pipe for: " ++ show sockAddr
        bracket open close $ \() -> do
            let pAs = do
                    _ <- view decoded (fromSocket socket 4096)
                    return ()

                notifyNext = do
                    send socket (ByteString.singleton magicByteNext)
                    for pAs $ \a -> do
                        yield a
                        send socket (ByteString.singleton magicByteNext)

                pBs = for (getter notifyNext) encode

                notifyYield = do
                    for pBs $ \b -> do
                        send socket (ByteString.singleton magicByteYield)
                        yield b

--              notifyReturn = do
--                  notifyYield
--                  send socket (ByteString.singleton magicByteReturn)

            runEffect $ for notifyYield (send socket)

-- | A managed resource
newtype Managed r = Managed { _bind :: forall x . (r -> IO x) -> IO x }

instance Functor Managed where
    fmap f mx = Managed (\_return ->
        _bind mx (\x ->
        _return (f x) ) )

instance Applicative Managed where
    pure r    = Managed (\_return ->
        _return r )
    mf <*> mx = Managed (\_return ->
        _bind mf (\f ->
        _bind mx (\x ->
        _return (f x) ) ) )

newtype PaaS a b = PaaS
    { unPaaS :: Managed (Producer a IO () -> Producer b IO ()) }

instance Category PaaS where
    id = PaaS (pure id)

    PaaS mf . PaaS mx = PaaS (liftA2 (.) mf mx)

-- | 'install' a 'deploy'ed 'Pipe'
install
    :: (Binary a, Binary b)
    => HostName
    -> ServiceName
    -> PaaS a b
install hostName serviceName = PaaS $ Managed $ \k -> do
    connect hostName serviceName $ \(socket, _) -> do
        let f pSocket0 pAs0 = do
                x <- lift $ nextByte pSocket0
                case x of
                    Left   ()            -> return ()
                    Right (w8, pSocket1) -> case () of
                        _ | w8 == magicByteNext  -> do
                            y <- lift $ next pAs0
                            case y of
                                Left   ()       -> return ()
                                Right (a, pAs1) -> do
                                    for (encode a) (send socket)
                                    f pSocket1 pAs1
                          | w8 == magicByteYield -> do
                            (y, pSocket2) <- lift $ runStateT decode pSocket1
                            case y of
                                Left  err -> lift $ throwIO err
                                Right a   -> do
                                    yield a
                                    f pSocket2 pAs0
                          | otherwise            -> do
                            lift $ throwIO (userError "Invalid magic byte")

            f' = f (fromSocket socket 4096)

        k f'
