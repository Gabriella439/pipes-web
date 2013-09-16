{-# LANGUAGE TypeFamilies #-}

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

    -- * Re-exports
    HostPreference(..),
    HostName,
    ServiceName,
    withSocketsDo
    ) where

import Control.Monad (when)
import Control.Monad.Trans.State.Strict (StateT, evalStateT)
import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import Data.Word (Word8)
import Network.Socket.ByteString (sendAll)
import Pipes
import Pipes.Internal (unsafeHoist)
import Pipes.Lift (evalStateP)
import qualified Pipes.Network.TCP as PN
import Pipes.Network.TCP (
    HostPreference(..), ServiceName, HostName, withSocketsDo)
import qualified Pipes.Network.TCP.Safe as Safe
import Pipes.Safe (MonadSafe, Base)
import qualified Pipes.ByteString as PB
import Pipes.Binary (encode, decode)

import Data.Binary (Binary)

-- Chosen by fair 1d256 rolls

magicNumberAwait :: Word8
magicNumberAwait = 23

magicNumberYield :: Word8
magicNumberYield = 146

upstream
    :: (MonadIO m, Binary a)
    => PN.Socket -> Producer a (StateT (Producer ByteString m r) m) ()
upstream socket = go
  where
    go = do
        liftIO $ sendAll socket (B.singleton magicNumberAwait)
        y <- lift decode
        case y of
            Right (_, a) -> do
                yield a
                go
            _  -> return ()

downstream
    :: (MonadIO m, Binary b)
    => PN.Socket -> Consumer b (StateT (Producer ByteString m r) m) ()
downstream socket = go >-> PN.toSocket socket
  where
    go = do
        x <- lift PB.draw
        case x of
            Right 0 -> do
                b <- await
                liftIO $ sendAll socket (B.singleton magicNumberYield)
                encode b
                go
            _ -> return ()

-- | 'deploy' a 'Pipe' that others can 'install'
deploy
    :: (Binary a, Binary b)
    => HostPreference -> ServiceName -> Pipe a b IO () -> IO ()
deploy hostPreference serviceName pipe =
    PN.serve hostPreference serviceName $ \(socket, sockAddr) -> do
        putStrLn $ "Opening pipe for: " ++ show sockAddr
        (`evalStateT` (PN.fromSocket socket 4096)) $ runEffect $
            upstream socket >-> unsafeHoist lift pipe >-> downstream socket
        putStrLn $ "Closing pipe for: " ++ show sockAddr

-- | 'install' a 'deploy'ed 'Pipe'
install
    :: (Binary a, Binary b, MonadSafe m, Base m ~ IO)
    => HostName -> ServiceName -> Pipe a b m ()
install hostName serviceName =
    Safe.connect hostName serviceName $ \(socket, _) -> do
        evalStateP (PN.fromSocket socket 4096) $ do
            let go amDownstream = do
                    when amDownstream $ liftIO $ sendAll socket (B.singleton 0)
                    x <- lift PB.draw
                    case x of
                        Right w8
                            | w8 == magicNumberAwait -> do
                                a <- await
                                for (encode a) (liftIO . sendAll socket)
                                go False
                            | w8 == magicNumberYield -> do
                                y <- lift decode
                                case y of
                                    Right (_, b) -> do
                                        yield b
                                        go True
                                    Left _  -> return ()
                        _ -> return ()
            go True
