// SPDX-License-Identifier: GPL-2.0-or-later
//
// The host channel's server (Server, HostFrame, and VsockListener over a scripted android.system.Os) on a
// plain JVM: admission by the peer's CID, the frame, the handler's results, the order of the connections,
// the listening socket's retries, and the record's entry point behind the shipped server. The rows are U4 of
// the channel's design and R23 of the record's. test_sms_service.py runs it.

package android.kernarium.sms;

import static android.kernarium.sms.Checks.check;
import static android.kernarium.sms.Checks.same;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import android.system.VmSocketAddress;
import java.io.ByteArrayOutputStream;
import java.io.FileDescriptor;
import java.io.IOException;
import java.net.SocketAddress;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Deque;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;

public final class ChannelTest {
    private static Golden golden;

    private ChannelTest() {}

    private static byte[] frame(String name) {
        return Golden.bytes(golden.after(name));
    }

    private static byte[] concat(byte[]... parts) {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] part : parts) out.write(part, 0, part.length);
        return out.toByteArray();
    }

    /** A connection the test scripts: what the peer sent, who it is, and what the server did with it. */
    static final class Script implements Server.Conn {
        final List<String> events;
        int cid = 2;
        /** The accept reported no peer address. */
        boolean peerThrows;
        byte[] incoming = new byte[0];
        int position;
        int maxPerRead = Integer.MAX_VALUE;
        /** The stream ends after the bytes (the host gave up); otherwise the peer goes quiet and a read waits out its deadline. */
        boolean ends;
        /** Bytes that arrive only after the server's look for more. */
        byte[] late;
        final ByteArrayOutputStream written = new ByteArrayOutputStream();
        boolean closed;

        Script(List<String> events) {
            this.events = events;
        }

        Script sends(byte[]... parts) {
            incoming = concat(parts);
            return this;
        }

        @Override
        public int peerCid() throws Exception {
            events.add("peer");
            if (peerThrows) throw new IOException("accept gave no peer address");
            return cid;
        }

        @Override
        public int read(byte[] buffer, int offset, int length, long deadlineNanos) throws IOException {
            events.add("read");
            if (position < incoming.length) {
                final int n = Math.min(Math.min(length, maxPerRead), incoming.length - position);
                System.arraycopy(incoming, position, buffer, offset, n);
                position += n;
                return n;
            }
            if (ends) return 0;
            throw new IOException("the deadline passed");
        }

        @Override
        public boolean readableNow() {
            events.add("look");
            final boolean readable = position < incoming.length || ends;
            if (!readable && late != null) {
                incoming = concat(incoming, late);
                late = null;
            }
            return readable;
        }

        @Override
        public void write(byte[] bytes, long deadlineNanos) {
            events.add("write");
            written.write(bytes, 0, bytes.length);
        }

        @Override
        public void close() {
            events.add("close");
            closed = true;
        }
    }

    /** The connections the kernel queued, in order. */
    static final class Queue implements Server.Listener {
        final BlockingQueue<Server.Conn> conns = new LinkedBlockingQueue<>();
        final AtomicInteger accepts = new AtomicInteger();
        final List<String> events;

        Queue(List<String> events) {
            this.events = events;
        }

        @Override
        public Server.Conn accept() throws IOException {
            events.add("accept");
            accepts.incrementAndGet();
            try {
                final Server.Conn conn = conns.poll(30, TimeUnit.SECONDS);
                if (conn == null) throw new IOException("nothing queued");
                return conn;
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted");
            }
        }
    }

    /** What the handler saw and what it answers. */
    static final class Handling implements Server.Handler {
        final List<byte[]> payloads = Collections.synchronizedList(new ArrayList<>());
        volatile Function<byte[], byte[]> answers = payload -> "2.ok".getBytes(StandardCharsets.US_ASCII);

        @Override
        public byte[] handle(byte[] payload) {
            payloads.add(payload);
            return answers.apply(payload);
        }
    }

    private static Server server(Queue queue, Server.Handler handler, List<String> log) {
        return new Server(queue, handler, log::add, System::nanoTime, 1);
    }

    private static Script serve(Server.Handler handler, List<String> log, Script conn) throws Exception {
        final Queue queue = new Queue(conn.events);
        queue.conns.add(conn);
        server(queue, handler, log).serveOne();
        return conn;
    }

    /** Admission: only CID 2 is read from, and the peer is asked before any read. */
    private static void admission() throws Exception {
        final byte[] request = frame("frame-request-first-number");
        final int[] refused = {0, 1, 3, -1};
        for (int cid : refused) {
            final List<String> events = new ArrayList<>();
            final Handling handling = new Handling();
            final Script conn = new Script(events).sends(request);
            conn.cid = cid;
            serve(handling, new ArrayList<>(), conn);
            check(!events.contains("read") && !events.contains("write") && !events.contains("look"),
                    "CID " + cid + " was neither read nor written: " + events);
            check(conn.closed && handling.payloads.isEmpty(), "CID " + cid + " is closed and not dispatched");
        }
        final List<String> events = new ArrayList<>();
        final Script strange = new Script(events).sends(request);
        strange.peerThrows = true;
        final Handling handling = new Handling();
        final List<String> unaddressedLog = new ArrayList<>();
        serve(handling, unaddressedLog, strange);
        check(!events.contains("read") && !events.contains("write") && !events.contains("look") && strange.closed
                && handling.payloads.isEmpty(), "a connection with no peer address is refused unread: " + events);
        same(1, unaddressedLog.size(), "and said so once: " + unaddressedLog);
        check(!unaddressedLog.isEmpty()
                && unaddressedLog.get(0).startsWith("refused a connection with no peer address"),
                "in the line that says what it was: " + unaddressedLog);
        check(unaddressedLog.stream().allMatch(line -> line.chars().noneMatch(Character::isDigit)),
                "which names no CID or port");
        final List<String> admittedEvents = new ArrayList<>();
        final Script host = new Script(admittedEvents).sends(request);
        serve(handling, new ArrayList<>(), host);
        check(admittedEvents.indexOf("peer") >= 0 && admittedEvents.indexOf("peer") < admittedEvents.indexOf("read"),
                "the peer is asked before the first read: " + admittedEvents);
        same(1, handling.payloads.size(), "CID 2 is served");
        // The refusal is logged for the first connection, then one in 256.
        final List<String> log = new ArrayList<>();
        final Queue queue = new Queue(new ArrayList<>());
        for (int i = 0; i < 300; ++i) {
            final Script conn = new Script(new ArrayList<>());
            conn.cid = 1;
            queue.conns.add(conn);
        }
        final Server loop = server(queue, new Handling(), log);
        for (int i = 0; i < 300; ++i) loop.serveOne();
        same(2, log.size(), "two refusals logged of 300: " + log);
        check(!log.isEmpty() && log.get(0).contains("CID 1"), "the log names the CID");
        // A connection with no peer address is logged for the first, then one in 256, apart from the refusals.
        final List<String> unaddressed = new ArrayList<>();
        final Queue strangers = new Queue(new ArrayList<>());
        for (int i = 0; i < 300; ++i) {
            final Script conn = new Script(new ArrayList<>());
            conn.peerThrows = true;
            strangers.conns.add(conn);
        }
        final Server watch = server(strangers, new Handling(), unaddressed);
        for (int i = 0; i < 300; ++i) watch.serveOne();
        same(2, unaddressed.size(), "two unaddressed connections logged of 300: " + unaddressed);
    }

    /** The frame: the bytes of the golden file, one at a time, cut, and with more than one frame. */
    private static void framing() throws Exception {
        final byte[] request = frame("frame-request-first-number");
        final byte[] zero = frame("frame-answer-zero");
        final byte[] payload = Golden.bytes(golden.fields("frame-request-first-number")[0]);
        // A frame that arrives a byte at a time is dispatched once, with its payload.
        {
            final Handling handling = new Handling();
            handling.answers = p -> Golden.bytes(golden.fields("frame-answer-handed-over-1")[0]);
            final Script conn = new Script(new ArrayList<>()).sends(request);
            conn.maxPerRead = 1;
            serve(handling, new ArrayList<>(), conn);
            same(1, handling.payloads.size(), "one dispatch");
            check(Arrays.equals(payload, handling.payloads.get(0)), "with the payload of the frame");
            check(Arrays.equals(frame("frame-answer-handed-over-1"), conn.written.toByteArray()), "and the golden answer frame");
        }
        // Cut short, by the end of the stream and by the deadline: never dispatched, never answered.
        for (int cut : new int[] {0, 3, 7, 8, 20, request.length - 1}) {
            for (boolean ends : new boolean[] {true, false}) {
                final Handling handling = new Handling();
                final Script conn = new Script(new ArrayList<>()).sends(Arrays.copyOf(request, cut));
                conn.ends = ends;
                serve(handling, new ArrayList<>(), conn);
                check(handling.payloads.isEmpty() && conn.written.size() == 0 && conn.closed,
                        "a frame cut at " + cut + (ends ? " by the end" : " by the deadline") + " is dropped");
            }
        }
        // A header the server refuses: the zero-length answer, no dispatch.
        for (String name : new String[] {"reject-magic", "reject-version", "reject-version-0", "reject-request-length-0",
            "reject-request-length-8193"}) {
            final Handling handling = new Handling();
            final Script conn = new Script(new ArrayList<>()).sends(Golden.bytes(golden.fields(name)[0]));
            serve(handling, new ArrayList<>(), conn);
            check(handling.payloads.isEmpty(), name + ": no dispatch");
            check(Arrays.equals(zero, conn.written.toByteArray()), name + ": the zero-length answer");
        }
        // The longest request is dispatched.
        {
            final Handling handling = new Handling();
            final byte[] longest = frame("frame-request-longest");
            final Script conn = new Script(new ArrayList<>()).sends(longest);
            serve(handling, new ArrayList<>(), conn);
            same(1, handling.payloads.size(), "the longest request");
            same(2750, handling.payloads.get(0).length, "2,750 bytes");
            final byte[] header8192 = Golden.bytes(golden.fields("header-request-8192")[0]);
            final Handling most = new Handling();
            serve(most, new ArrayList<>(), new Script(new ArrayList<>()).sends(header8192, new byte[8192]));
            same(8192, most.payloads.isEmpty() ? -1 : most.payloads.get(0).length, "8,192 bytes is the most");
        }
        // More than the one frame: the zero-length answer and no dispatch.
        for (byte[] extra : new byte[][] {request, new byte[] {0x0a}}) {
            final Handling handling = new Handling();
            final Script conn = new Script(new ArrayList<>()).sends(request, extra);
            serve(handling, new ArrayList<>(), conn);
            check(handling.payloads.isEmpty(), "bytes after the frame: no dispatch");
            check(Arrays.equals(zero, conn.written.toByteArray()), "bytes after the frame: the zero-length answer");
        }
        // Bytes that come after the look are never read: one dispatch, no answer to them.
        {
            final Handling handling = new Handling();
            final Script conn = new Script(new ArrayList<>()).sends(request);
            conn.ends = false;
            conn.late = request;
            serve(handling, new ArrayList<>(), conn);
            same(1, handling.payloads.size(), "one dispatch of two frames");
            same(request.length, conn.position, "the late frame is never read");
        }
        // The end of the stream right after the frame: the host gave up, nothing is dispatched.
        {
            final Handling handling = new Handling();
            final Script conn = new Script(new ArrayList<>()).sends(request);
            conn.ends = true;
            serve(handling, new ArrayList<>(), conn);
            check(handling.payloads.isEmpty() && conn.written.size() == 0, "the end of the stream after the frame: dropped");
        }
    }

    /** What the handler gives back. */
    private static void handlerResults() throws Exception {
        final byte[] request = frame("frame-request-first-number");
        final byte[] zero = frame("frame-answer-zero");
        for (int length : new int[] {1, 58, 4096}) {
            final Handling handling = new Handling();
            final byte[] answer = new byte[length];
            Arrays.fill(answer, (byte) 'a');
            handling.answers = p -> answer;
            final Script conn = new Script(new ArrayList<>()).sends(request);
            conn.ends = false;
            serve(handling, new ArrayList<>(), conn);
            check(Arrays.equals(HostFrame.encode(answer), conn.written.toByteArray()), length + " bytes go out as one frame");
        }
        {
            final Handling handling = new Handling();
            handling.answers = p -> new byte[0];
            final Script conn = new Script(new ArrayList<>()).sends(request);
            conn.ends = false;
            final List<String> log = new ArrayList<>();
            serve(handling, log, conn);
            same(1, handling.payloads.size(), "the handler is called once");
            check(Arrays.equals(zero, conn.written.toByteArray()), "an empty result: exactly the zero-length answer");
            same(1, Collections.frequency(conn.events, "write"), "written once");
            check(log.isEmpty(), "nothing logged");
        }
        for (String how : new String[] {"throws", "too long"}) {
            final Handling handling = new Handling();
            final boolean throwing = how.equals("throws");
            handling.answers = p -> {
                if (throwing) throw new IllegalStateException("handler failed: " + new String(p, StandardCharsets.US_ASCII));
                return new byte[4097];
            };
            final Queue queue = new Queue(new ArrayList<>());
            final Script bad = new Script(queue.events).sends(request);
            bad.ends = false;
            final Script next = new Script(queue.events).sends(request);
            next.ends = false;
            queue.conns.add(bad);
            queue.conns.add(next);
            final List<String> log = new ArrayList<>();
            final Server server = server(queue, handling, log);
            server.serveOne();
            check(bad.written.size() == 0 && bad.closed, how + ": no answer, closed");
            same(1, log.size(), how + ": one log line");
            check(!log.get(0).contains("2.first") && !log.get(0).contains("failed: 2."), how + ": no payload byte logged: " + log);
            handling.answers = p -> new byte[] {'o', 'k'};
            server.serveOne();
            check(Arrays.equals(HostFrame.encode(new byte[] {'o', 'k'}), next.written.toByteArray()),
                    how + ": the next connection is served");
        }
        // The golden frames of the longest answer.
        final Handling longest = new Handling();
        longest.answers = p -> Golden.bytes(golden.fields("frame-answer-longest")[0]);
        final Script conn = new Script(new ArrayList<>()).sends(request);
        conn.ends = false;
        serve(longest, new ArrayList<>(), conn);
        check(Arrays.equals(frame("frame-answer-longest"), conn.written.toByteArray()), "the 58-byte answer, framed");
        same(66, conn.written.size(), "66 bytes framed");
    }

    /** P3: one connection at a time, to completion, in accept order. */
    private static void order() throws Exception {
        final byte[] first = frame("frame-request-first-number");
        final byte[] second = frame("frame-request-first-number").clone();
        second[HostFrame.HEADER_BYTES + 2] = 'r'; // 2.rirst...: only to tell the payloads apart
        final CountDownLatch inside = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final Handling handling = new Handling();
        handling.answers = payload -> {
            if (payload[2] == 'f') {
                inside.countDown();
                try {
                    release.await(30, TimeUnit.SECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            return new byte[] {'o', 'k'};
        };
        final Queue queue = new Queue(new ArrayList<>());
        final Script a = new Script(queue.events).sends(first);
        a.ends = false;
        final Script b = new Script(queue.events).sends(second);
        b.ends = false;
        queue.conns.add(a);
        queue.conns.add(b);
        final Server server = server(queue, handling, new ArrayList<>());
        final Thread thread = new Thread(server);
        thread.start();
        check(inside.await(20, TimeUnit.SECONDS), "the first handler is entered");
        Thread.sleep(200); // one-sided: a second accept thread would have taken the second connection by now
        same(1, queue.accepts.get(), "no second accept while the first handler runs");
        same(1, handling.payloads.size(), "the second request is not dispatched");
        release.countDown();
        final long deadline = System.nanoTime() + 20_000_000_000L;
        while (queue.accepts.get() < 3 && System.nanoTime() < deadline) Thread.sleep(2);
        thread.interrupt();
        thread.join(30_000);
        same(2, handling.payloads.size(), "both dispatched");
        check(handling.payloads.size() == 2 && handling.payloads.get(0)[2] == 'f' && handling.payloads.get(1)[2] == 'r',
                "in accept order");
        // A timed-out original, then its retry: the original is dispatched first or not at all.
        for (boolean closedByHost : new boolean[] {true, false}) {
            final Handling seen = new Handling();
            final Queue q = new Queue(new ArrayList<>());
            final Script original = new Script(q.events).sends(first);
            original.ends = closedByHost;
            final Script retry = new Script(q.events).sends(second);
            retry.ends = false;
            q.conns.add(original);
            q.conns.add(retry);
            final Server s = server(q, seen, new ArrayList<>());
            s.serveOne();
            s.serveOne();
            if (closedByHost) {
                same(1, seen.payloads.size(), "the host's cancel: only the retry is dispatched");
                check(seen.payloads.get(0)[2] == 'r', "the retry");
            } else {
                same(2, seen.payloads.size(), "the original still open: both dispatched");
                check(seen.payloads.size() == 2 && seen.payloads.get(0)[2] == 'f', "the original first");
            }
        }
    }

    /** R23: the shipped server and the shipped entry point, with a payload the parser refuses. */
    private static void emptyResult() throws Exception {
        final Path dir = Files.createTempDirectory("sms-empty-");
        try {
            final Rig rig = new Rig(dir);
            final Rig.Recording files = new Rig.Recording(new RecordFiles.Nio(dir));
            final DeliveryService service = new DeliveryService(rig.record(files, RecordStore.CAPACITY));
            final byte[] refused = ("2.first." + Rig.X + "."
                    + java.util.Base64.getEncoder().encodeToString("Bank".getBytes(StandardCharsets.UTF_8)) + ".YQ")
                    .getBytes(StandardCharsets.US_ASCII);
            final byte[] ok = SmsServiceTest.request("first", Rig.X, "Bank", "hello");
            final Queue queue = new Queue(new ArrayList<>());
            final Script a = new Script(queue.events).sends(HostFrame.encode(refused));
            a.ends = false;
            final Script b = new Script(queue.events).sends(HostFrame.encode(ok));
            b.ends = false;
            queue.conns.add(a);
            queue.conns.add(b);
            final Server server = server(queue, service, new ArrayList<>());
            server.serveOne();
            check(Arrays.equals(frame("frame-answer-zero"), a.written.toByteArray()), "exactly the zero-length answer frame");
            check(files.ops.isEmpty(), "no record file was touched: " + files.ops);
            same(0, rig.stepRuns.get(), "no step");
            same(0, rig.plans.get(), "no plan");
            server.serveOne();
            check(Arrays.equals(HostFrame.encode(("2.handed-over." + Rig.X + ".1").getBytes(StandardCharsets.US_ASCII)),
                    b.written.toByteArray()), "the loop serves the next connection");
        } finally {
            try (java.util.stream.Stream<Path> walk = Files.walk(dir)) {
                walk.sorted(java.util.Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
    }

    /** The world the glue sees: sockets that the test queues, each with a peer and what it sends. */
    static final class World implements Os.Backend {
        static final class Sock {
            /** The peer's CID, as accept fills it into the address it is given; null: it leaves the address alone. */
            Integer cid;
            int port = 51234;
            /** The library cannot convert the peer's address: accept closes the connection and returns null. */
            boolean libraryRefuses;
            byte[] incoming = new byte[0];
            int position;
            boolean ends = true;
            final ByteArrayOutputStream written = new ByteArrayOutputStream();
            boolean shutdown;
            boolean closed;
            boolean nonblocking;
            boolean closeOnExec;
        }

        final List<String> calls = Collections.synchronizedList(new ArrayList<>());
        final Map<FileDescriptor, Sock> socks = new HashMap<>();
        final Deque<Sock> queued = new ArrayDeque<>();
        final FileDescriptor listener = new FileDescriptor();
        final List<ErrnoException> bindFailures = new ArrayList<>();
        final List<ErrnoException> acceptFailures = new ArrayList<>();
        /** A failure of the other kinds, thrown by the next accept that is polled ready. */
        Exception acceptOther;
        /** The address each accept was given to fill. */
        final List<SocketAddress> acceptAddresses = new ArrayList<>();
        SocketAddress bound;
        int listens;
        int sockets;

        @Override
        public FileDescriptor socket(int domain, int type, int protocol) {
            calls.add("socket " + domain);
            ++sockets;
            return listener;
        }

        @Override
        public void bind(FileDescriptor fd, SocketAddress address) throws ErrnoException {
            calls.add("bind");
            if (!bindFailures.isEmpty()) throw bindFailures.remove(0);
            bound = address;
        }

        @Override
        public void listen(FileDescriptor fd, int backlog) {
            calls.add("listen");
            ++listens;
        }

        /** Like libjavacore's accept: a VmSocketAddress it is given is filled with the peer's port and CID. */
        @Override
        public FileDescriptor accept(FileDescriptor fd, SocketAddress peer) throws ErrnoException, SocketException {
            calls.add("accept");
            acceptAddresses.add(peer);
            if (!acceptFailures.isEmpty()) throw acceptFailures.remove(0);
            if (acceptOther != null) {
                final Exception failure = acceptOther;
                acceptOther = null;
                if (failure instanceof SocketException) throw (SocketException) failure;
                throw (RuntimeException) failure;
            }
            final Sock sock = queued.poll();
            if (sock == null) throw new ErrnoException("accept", OsConstants.EAGAIN);
            if (sock.libraryRefuses) {
                sock.closed = true;
                return null;
            }
            if (peer instanceof VmSocketAddress && sock.cid != null) fill((VmSocketAddress) peer, sock.port, sock.cid);
            final FileDescriptor child = new FileDescriptor();
            socks.put(child, sock);
            return child;
        }

        /** What the library's accept does through JNI: it sets the two fields of the address it was given. */
        private static void fill(VmSocketAddress address, int port, int cid) {
            try {
                set(address, "svmPort", port);
                set(address, "svmCid", cid);
            } catch (ReflectiveOperationException e) {
                throw new AssertionError(e);
            }
        }

        private static void set(VmSocketAddress address, String name, int value) throws ReflectiveOperationException {
            final java.lang.reflect.Field field = VmSocketAddress.class.getDeclaredField(name);
            field.setAccessible(true);
            field.setInt(address, value);
        }

        @Override
        public int poll(StructPollfd[] fds, int timeoutMillis) {
            int ready = 0;
            for (StructPollfd p : fds) {
                p.revents = 0;
                if (p.fd == listener) {
                    if ((p.events & OsConstants.POLLIN) != 0
                            && (!queued.isEmpty() || !acceptFailures.isEmpty() || acceptOther != null)) {
                        p.revents = (short) OsConstants.POLLIN;
                    }
                } else {
                    final Sock sock = socks.get(p.fd);
                    if ((p.events & OsConstants.POLLOUT) != 0) p.revents = (short) OsConstants.POLLOUT;
                    if ((p.events & OsConstants.POLLIN) != 0 && (sock.position < sock.incoming.length || sock.ends)) {
                        p.revents = (short) OsConstants.POLLIN;
                    }
                }
                if (p.revents != 0) ++ready;
            }
            return ready;
        }

        @Override
        public int read(FileDescriptor fd, byte[] buffer, int offset, int length) {
            calls.add("read");
            final Sock sock = socks.get(fd);
            final int n = Math.min(length, sock.incoming.length - sock.position);
            System.arraycopy(sock.incoming, sock.position, buffer, offset, n);
            sock.position += n;
            return n;
        }

        @Override
        public int write(FileDescriptor fd, byte[] buffer, int offset, int length) {
            calls.add("write");
            final int n = Math.min(length, 7); // a short write: the glue must go on
            socks.get(fd).written.write(buffer, offset, n);
            return n;
        }

        @Override
        public void shutdown(FileDescriptor fd, int how) {
            calls.add("shutdown");
            socks.get(fd).shutdown = true;
        }

        @Override
        public void close(FileDescriptor fd) {
            calls.add(fd == listener ? "close listener" : "close");
            final Sock sock = socks.get(fd);
            if (sock != null) sock.closed = true;
        }

        @Override
        public int fcntlInt(FileDescriptor fd, int command, int argument) {
            calls.add("fcntl");
            final Sock sock = socks.get(fd);
            if (command == OsConstants.F_SETFD) {
                sock.closeOnExec = argument == OsConstants.FD_CLOEXEC;
            } else {
                sock.nonblocking = command == OsConstants.F_SETFL && argument == OsConstants.O_NONBLOCK;
            }
            return 0;
        }
    }

    private static final class Pauses implements VsockListener.Sleeper {
        final List<Long> pauses = new ArrayList<>();

        @Override
        public void sleep(long millis) {
            pauses.add(millis);
        }
    }

    /** The glue over a scripted world: the peer's CID, the short writes, the listener's retries. */
    private static void glue() throws Exception {
        final World world = new World();
        Os.backend = world;
        final byte[] request = frame("frame-request-first-number");
        final byte[] answer = frame("frame-answer-handed-over-1");
        final Handling handling = new Handling();
        handling.answers = p -> Golden.bytes(golden.fields("frame-answer-handed-over-1")[0]);
        final Pauses pauses = new Pauses();
        final List<String> log = new ArrayList<>();
        final VsockListener listener = new VsockListener(log::add, pauses);
        final Server server = new Server(listener, handling, log::add, System::nanoTime, 1);

        // The host, a byte at a time, and a short write on the way back.
        final World.Sock host = new World.Sock();
        host.cid = OsConstants.VMADDR_CID_HOST;
        host.incoming = request;
        host.ends = false;
        world.queued.add(host);
        server.serveOne();
        same(1, handling.payloads.size(), "the host's request is dispatched");
        check(Arrays.equals(answer, host.written.toByteArray()), "the answer arrived whole over short writes");
        check(host.shutdown && host.closed && host.nonblocking, "shut down, closed, and non-blocking");
        check(host.closeOnExec, "the accepted descriptor is close-on-exec");
        check(world.bound instanceof VmSocketAddress && ((VmSocketAddress) world.bound).getSvmPort() == 5560
                && ((VmSocketAddress) world.bound).getSvmCid() == OsConstants.VMADDR_CID_ANY, "listening on port 5560, any CID");
        same("socket " + OsConstants.AF_VSOCK, world.calls.get(0), "a vsock socket");
        check(log.contains("listening on vsock port 5560"), "the first listen is logged");
        // The peer is what accept reported: the address it was given to fill, never getpeername, which
        // fails for AF_VSOCK on the image (the stub's Os.getpeername throws as the guest's library does).
        check(world.acceptAddresses.size() == 1 && world.acceptAddresses.get(0) instanceof VmSocketAddress,
                "accept is given a VmSocketAddress to fill: " + world.acceptAddresses);
        final int firstRead = world.calls.indexOf("read");
        check(firstRead > world.calls.indexOf("accept") && world.calls.indexOf("accept") >= 0,
                "the peer is known from the accept, before the first read: " + world.calls);
        check(!log.stream().anyMatch(line -> line.startsWith("refused")), "the host is not refused: " + log);

        // Another CID: closed unread and unwritten, and refused in the line that names it, once.
        final int refusalsLogged = log.size();
        for (int cid : new int[] {0, 1, 3, 4, Integer.MIN_VALUE}) {
            final int callsBefore = world.calls.size();
            final World.Sock other = new World.Sock();
            other.cid = cid;
            other.incoming = request;
            other.ends = false; // a request that was admitted would be dispatched
            world.queued.add(other);
            handling.payloads.clear();
            server.serveOne();
            final List<String> calls = new ArrayList<>(world.calls.subList(callsBefore, world.calls.size()));
            check(!calls.contains("read") && !calls.contains("write") && other.closed && other.shutdown,
                    "a peer with CID " + cid + " is closed unread: " + calls);
            check(handling.payloads.isEmpty(), "and not dispatched");
        }
        same(Arrays.asList("refused a connection from CID 0"), log.subList(refusalsLogged, log.size()),
                "the first refusal is logged with its CID");

        // No address: the accept left the address alone, or filled the CID that no peer has. Closed unread and
        // unwritten, never served, and said so (once) in a line with no CID or port in it.
        final int unaddressedLogged = log.size();
        for (Integer cid : new Integer[] {null, OsConstants.VMADDR_CID_ANY}) {
            final int callsBefore = world.calls.size();
            final World.Sock other = new World.Sock();
            other.cid = cid;
            other.incoming = request;
            other.ends = false; // a request that was admitted would be dispatched
            world.queued.add(other);
            handling.payloads.clear();
            server.serveOne();
            final List<String> calls = new ArrayList<>(world.calls.subList(callsBefore, world.calls.size()));
            check(!calls.contains("read") && !calls.contains("write") && other.closed && other.shutdown,
                    "a peer whose address is " + cid + " is closed unread: " + calls);
            check(handling.payloads.isEmpty(), "and not dispatched");
        }
        same(Arrays.asList("refused a connection with no peer address: IOException"),
                log.subList(unaddressedLogged, log.size()), "the first of them is logged, with no CID or port");

        // A connection whose address the library cannot convert is closed by it, never reaches the server,
        // and the next one is served.
        final World.Sock unconvertible = new World.Sock();
        unconvertible.libraryRefuses = true;
        unconvertible.incoming = request;
        final World.Sock next = new World.Sock();
        next.cid = OsConstants.VMADDR_CID_HOST;
        next.incoming = request;
        next.ends = false;
        world.queued.add(unconvertible);
        world.queued.add(next);
        handling.payloads.clear();
        server.serveOne();
        check(unconvertible.closed && !unconvertible.shutdown && unconvertible.written.size() == 0,
                "an address the library cannot convert is closed unread");
        same(1, handling.payloads.size(), "and the next connection, the host's, is served");

        // The host and then a connection whose address accept leaves alone: each accept gets an address of its own,
        // so the host's CID is not carried over to it.
        final int callsBeforeUntouched = world.calls.size();
        final World.Sock untouched = new World.Sock();
        untouched.incoming = request;
        untouched.ends = false; // a request that was admitted would be dispatched
        world.queued.add(untouched);
        handling.payloads.clear();
        server.serveOne();
        final List<String> untouchedCalls = new ArrayList<>(world.calls.subList(callsBeforeUntouched, world.calls.size()));
        check(!untouchedCalls.contains("read") && !untouchedCalls.contains("write") && untouched.closed
                && untouched.shutdown, "an untouched address after the host is closed unread: " + untouchedCalls);
        check(handling.payloads.isEmpty(), "and not dispatched, as if it were the host's");

        // A deadline that has nearly passed, and a peer that says nothing: dropped.
        final World.Sock quiet = new World.Sock();
        quiet.cid = OsConstants.VMADDR_CID_HOST;
        quiet.ends = false;
        world.queued.add(quiet);
        final Server hurried = new Server(listener, handling, log::add, () -> System.nanoTime() - 4_999_000_000L, 1);
        handling.payloads.clear();
        hurried.serveOne();
        check(handling.payloads.isEmpty() && quiet.written.size() == 0 && quiet.closed, "a silent peer is dropped at the deadline");

        // The bind fails twice: tried again after a second each time, and complained about once.
        final World again = new World();
        Os.backend = again;
        again.bindFailures.add(new ErrnoException("bind", OsConstants.EADDRINUSE));
        again.bindFailures.add(new ErrnoException("bind", OsConstants.EADDRINUSE));
        final Pauses waits = new Pauses();
        final List<String> logAgain = new ArrayList<>();
        final VsockListener patient = new VsockListener(logAgain::add, waits);
        final World.Sock one = new World.Sock();
        one.cid = OsConstants.VMADDR_CID_HOST;
        again.queued.add(one);
        final Server.Conn conn = patient.accept();
        check(conn != null, "the listener was set up after two failures");
        same(Arrays.asList(1000L, 1000L), waits.pauses, "a second between tries");
        same(3, again.sockets, "a new socket for each try");
        same(1L, logAgain.stream().filter(l -> l.startsWith("host channel: cannot listen")).count(),
                "the failure is logged once");
        conn.close();

        // An accept that is interrupted goes on; one that fails otherwise closes the listener and listens again.
        again.acceptFailures.add(new ErrnoException("accept", OsConstants.EINTR));
        again.acceptFailures.add(new ErrnoException("accept", OsConstants.ECONNABORTED));
        final World.Sock two = new World.Sock();
        two.cid = OsConstants.VMADDR_CID_HOST;
        again.queued.add(two);
        final int socketsBefore = again.sockets;
        check(patient.accept() != null, "accept goes on after EINTR and ECONNABORTED");
        same(socketsBefore, again.sockets, "without listening again");
        again.acceptFailures.add(new ErrnoException("accept", 24));
        final World.Sock three = new World.Sock();
        three.cid = OsConstants.VMADDR_CID_HOST;
        again.queued.add(three);
        check(patient.accept() != null, "accept goes on after another failure");
        same(socketsBefore + 1, again.sockets, "with a new listener");
        check(again.calls.contains("close listener"), "the old listener was closed");
        Os.backend = null;
    }

    /**
     * The hidden overload of accept is reached by reflection. Its failures come out as they went in, and when it
     * cannot be found every connection is refused with nothing read, however the host asks.
     */
    private static void hiddenAccept() throws Exception {
        final byte[] request = frame("frame-request-first-number");
        final World world = new World();
        Os.backend = world;
        final Handling handling = new Handling();
        final List<String> log = new ArrayList<>();
        final Pauses pauses = new Pauses();
        final Server server = new Server(new VsockListener(log::add, pauses, "acceptThatIsNotThere"), handling,
                log::add, System::nanoTime, 1);
        same(Arrays.asList("host channel: cannot read a peer's CID: NoSuchMethodException"), log,
                "a hidden method that cannot be found is logged once, when it is looked for");
        for (int i = 0; i < 3; ++i) {
            final int callsBefore = world.calls.size();
            final World.Sock host = new World.Sock();
            host.cid = OsConstants.VMADDR_CID_HOST;
            host.incoming = request;
            host.ends = false; // a request that was admitted would be dispatched
            world.queued.add(host);
            server.serveOne();
            final List<String> calls = new ArrayList<>(world.calls.subList(callsBefore, world.calls.size()));
            check(!calls.contains("read") && !calls.contains("write") && host.closed && host.shutdown,
                    "with no hidden accept, the host's connection " + i + " is refused unread: " + calls);
        }
        check(handling.payloads.isEmpty(), "and nothing is dispatched");
        check(world.acceptAddresses.size() == 3 && world.acceptAddresses.stream().allMatch(a -> a == null),
                "the public accept, which fills no address, took them: " + world.acceptAddresses);
        same(Arrays.asList("host channel: cannot read a peer's CID: NoSuchMethodException",
                "listening on vsock port 5560", "refused a connection with no peer address: IOException"), log,
                "each is refused for having no peer address, the line is rate limited");

        // The failures of the hidden accept come out as they went in, not wrapped.
        final World failing = new World();
        Os.backend = failing;
        final List<String> failingLog = new ArrayList<>();
        final VsockListener listener = new VsockListener(failingLog::add, new Pauses());
        check(failingLog.isEmpty(), "the real name is found, and nothing is logged: " + failingLog);
        failing.acceptOther = new IllegalStateException("scripted");
        failing.queued.add(new World.Sock());
        try {
            listener.accept();
            check(false, "a RuntimeException of the accept comes out");
        } catch (IllegalStateException e) {
            same("scripted", e.getMessage(), "a RuntimeException of the accept comes out as it was thrown");
        }
        failing.acceptOther = new SocketException("scripted");
        final World.Sock after = new World.Sock();
        after.cid = OsConstants.VMADDR_CID_HOST;
        failing.queued.add(after);
        final int socketsBefore = failing.sockets;
        check(listener.accept() != null, "after a SocketException the listener listens again and accepts");
        same(socketsBefore + 1, failing.sockets, "with a new listener");
        check(failingLog.contains("host channel: accept failed: SocketException"), "and said so: " + failingLog);
        Os.backend = null;
    }

    public static void main(String[] args) throws Exception {
        golden = Golden.load();
        admission();
        framing();
        handlerResults();
        order();
        emptyResult();
        glue();
        hiddenAccept();
        System.exit(Checks.finish());
    }
}
