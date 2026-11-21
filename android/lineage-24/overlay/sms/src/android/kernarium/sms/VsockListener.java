// SPDX-License-Identifier: Apache-2.0
package android.kernarium.sms;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import android.system.VmSocketAddress;
import java.io.FileDescriptor;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.net.SocketException;
import java.util.function.Consumer;

/**
 * The host channel's listening socket: vsock port 5560, on any CID, one connection at a time. It is the
 * only Android glue of the server, and names only the classes of android.system, so that a plain JVM can
 * compile it against stand-ins and run the server's tests over it. Which peer may be served is the
 * server's rule (CID 2); this class reports the peer's CID and never decides. The CID is the one that
 * accept fills into the address it is given: libjavacore converts an AF_VSOCK address there only, and
 * Os.getpeername throws for it. The overload of Os.accept that takes a SocketAddress is @hide, and the
 * public one fills an InetSocketAddress only, so the hidden one is found by reflection, once. The service
 * is signed with the platform key, which the platform exempts from the hidden-API restrictions. When the
 * method cannot be found, the public accept takes every connection and gives none a peer address, and the
 * server refuses each of them, so nothing is read and the failure is logged.
 *
 * <p>A bind that fails is tried again every second and never ends the service; an accept that fails for
 * any reason but EINTR, EAGAIN or ECONNABORTED closes the listener, waits a second and listens again.
 */
final class VsockListener implements Server.Listener {
    static final int PORT = 5560;
    private static final int BACKLOG = 4;
    private static final int WAKE_MILLIS = 1000;

    /** Waits; a test's does not. */
    interface Sleeper {
        void sleep(long millis) throws InterruptedException;
    }

    private final Consumer<String> log;
    private final Sleeper sleeper;
    /** Os.accept(FileDescriptor, SocketAddress), or null when it cannot be called. */
    private Method acceptWithAddress;
    private FileDescriptor listening;
    private boolean complained;

    VsockListener(Consumer<String> log, Sleeper sleeper) {
        this(log, sleeper, "accept");
    }

    /** {@code acceptName} is the hidden method's name: a test names one that is not there. */
    VsockListener(Consumer<String> log, Sleeper sleeper, String acceptName) {
        this.log = log;
        this.sleeper = sleeper;
        try {
            final Method method = Os.class.getDeclaredMethod(acceptName, FileDescriptor.class, SocketAddress.class);
            if (!Modifier.isStatic(method.getModifiers()) || method.getReturnType() != FileDescriptor.class) {
                throw new NoSuchMethodException(acceptName);
            }
            method.setAccessible(true);
            acceptWithAddress = method;
        } catch (ReflectiveOperationException | RuntimeException e) {
            log.accept("host channel: cannot read a peer's CID: " + e.getClass().getSimpleName());
        }
    }

    @Override
    public Server.Conn accept() throws IOException {
        for (;;) {
            if (listening == null) listen();
            try {
                if (!readable(listening, -1)) continue;
                // An address that accept leaves alone keeps the CID it starts with, which no peer has.
                final VmSocketAddress peer = new VmSocketAddress(0, OsConstants.VMADDR_CID_ANY);
                final FileDescriptor fd = acceptFrom(peer);
                if (fd == null) continue;
                return new Peer(fd, peer.getSvmCid());
            } catch (ErrnoException e) {
                if (e.errno == OsConstants.EINTR || e.errno == OsConstants.EAGAIN
                        || e.errno == OsConstants.ECONNABORTED) {
                    continue;
                }
                log.accept("host channel: accept failed, errno " + e.errno);
            } catch (IOException e) {
                log.accept("host channel: accept failed: " + e.getClass().getSimpleName());
            }
            closeListener();
            pause(WAKE_MILLIS);
        }
    }

    /** Accepts into the address when the hidden overload is there; otherwise the public one, which fills none. */
    private FileDescriptor acceptFrom(VmSocketAddress peer) throws ErrnoException, SocketException {
        if (acceptWithAddress != null) {
            try {
                return (FileDescriptor) acceptWithAddress.invoke(null, listening, peer);
            } catch (InvocationTargetException e) {
                final Throwable cause = e.getCause();
                if (cause instanceof ErrnoException) throw (ErrnoException) cause;
                if (cause instanceof SocketException) throw (SocketException) cause;
                if (cause instanceof RuntimeException) throw (RuntimeException) cause;
                if (cause instanceof Error) throw (Error) cause;
                throw new IllegalStateException(cause);
            } catch (IllegalAccessException e) {
                acceptWithAddress = null;
                log.accept("host channel: cannot read a peer's CID: " + e.getClass().getSimpleName());
            }
        }
        return Os.accept(listening, (InetSocketAddress) null);
    }

    private void listen() throws IOException {
        for (;;) {
            FileDescriptor fd = null;
            try {
                fd = Os.socket(OsConstants.AF_VSOCK, OsConstants.SOCK_STREAM | OsConstants.SOCK_CLOEXEC
                        | OsConstants.SOCK_NONBLOCK, 0);
                Os.bind(fd, new VmSocketAddress(PORT, OsConstants.VMADDR_CID_ANY));
                Os.listen(fd, BACKLOG);
                listening = fd;
                complained = false;
                log.accept("listening on vsock port " + PORT);
                return;
            } catch (ErrnoException | IOException e) {
                if (fd != null) closeQuietly(fd);
                if (!complained) {
                    complained = true;
                    log.accept("host channel: cannot listen on vsock port " + PORT + ": "
                            + (e instanceof ErrnoException ? "errno " + ((ErrnoException) e).errno
                                    : e.getClass().getSimpleName()));
                }
            }
            pause(WAKE_MILLIS);
        }
    }

    private void closeListener() {
        if (listening != null) closeQuietly(listening);
        listening = null;
    }

    private void pause(long millis) throws IOException {
        try {
            sleeper.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("interrupted");
        }
    }

    private static void closeQuietly(FileDescriptor fd) {
        try {
            Os.close(fd);
        } catch (ErrnoException e) {
            // nothing to do
        }
    }

    /** Polls one descriptor for input; false when the wait ended with nothing to read. */
    private static boolean readable(FileDescriptor fd, int timeoutMillis) throws ErrnoException {
        final StructPollfd poll = new StructPollfd();
        poll.fd = fd;
        poll.events = (short) OsConstants.POLLIN;
        final int ready = Os.poll(new StructPollfd[] {poll}, timeoutMillis);
        return ready > 0 && (poll.revents & (OsConstants.POLLIN | OsConstants.POLLHUP | OsConstants.POLLERR)) != 0;
    }

    /** An accepted connection, non-blocking: every read and write follows a poll on the time left. */
    private static final class Peer implements Server.Conn {
        private final FileDescriptor fd;
        private final int cid;

        Peer(FileDescriptor fd, int cid) throws ErrnoException {
            this.fd = fd;
            this.cid = cid;
            try {
                // accept does not set close-on-exec on the descriptor it returns.
                Os.fcntlInt(fd, OsConstants.F_SETFD, OsConstants.FD_CLOEXEC);
                Os.fcntlInt(fd, OsConstants.F_SETFL, OsConstants.O_NONBLOCK);
            } catch (ErrnoException e) {
                closeQuietly(fd);
                throw e;
            }
        }

        @Override
        public int peerCid() throws IOException {
            if (cid == OsConstants.VMADDR_CID_ANY) throw new IOException("accept gave no peer address");
            return cid;
        }

        @Override
        public int read(byte[] buffer, int offset, int length, long deadlineNanos) throws IOException {
            try {
                for (;;) {
                    final int wait = waitMillis(deadlineNanos);
                    if (!readable(fd, wait)) continue;
                    try {
                        return Math.max(0, Os.read(fd, buffer, offset, length));
                    } catch (ErrnoException e) {
                        if (e.errno != OsConstants.EAGAIN && e.errno != OsConstants.EINTR) throw e;
                    }
                }
            } catch (ErrnoException e) {
                throw new IOException("read failed, errno " + e.errno);
            }
        }

        @Override
        public boolean readableNow() throws IOException {
            try {
                return readable(fd, 0);
            } catch (ErrnoException e) {
                throw new IOException("poll failed, errno " + e.errno);
            }
        }

        @Override
        public void write(byte[] bytes, long deadlineNanos) throws IOException {
            try {
                int done = 0;
                while (done < bytes.length) {
                    final StructPollfd poll = new StructPollfd();
                    poll.fd = fd;
                    poll.events = (short) OsConstants.POLLOUT;
                    final int ready = Os.poll(new StructPollfd[] {poll}, waitMillis(deadlineNanos));
                    if (ready <= 0) continue;
                    if ((poll.revents & (OsConstants.POLLERR | OsConstants.POLLHUP)) != 0) {
                        throw new IOException("the peer is gone");
                    }
                    try {
                        done += Os.write(fd, bytes, done, bytes.length - done);
                    } catch (ErrnoException e) {
                        if (e.errno != OsConstants.EAGAIN && e.errno != OsConstants.EINTR) throw e;
                    }
                }
            } catch (ErrnoException e) {
                throw new IOException("write failed, errno " + e.errno);
            }
        }

        @Override
        public void close() {
            try {
                Os.shutdown(fd, OsConstants.SHUT_RDWR);
            } catch (ErrnoException e) {
                // already gone
            }
            closeQuietly(fd);
        }

        /** The wait until the deadline, at most a second so that a stray close elsewhere cannot hold it. */
        private static int waitMillis(long deadlineNanos) throws IOException {
            final long left = deadlineNanos - System.nanoTime();
            if (left <= 0) throw new IOException("the deadline passed");
            return (int) Math.min(WAKE_MILLIS, Math.max(1, left / 1_000_000L));
        }
    }
}
