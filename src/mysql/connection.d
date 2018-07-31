module mysql.connection;

import std.algorithm;
import std.array;
import std.conv : to;
import std.regex : ctRegex, matchFirst;
import std.string;
import std.traits;

import mysql.exception;
import mysql.packet;
import mysql.protocol;
import mysql.type;
import mysql.socket;
import mysql.row;
import mysql.utils;

immutable CapabilityFlags DefaultClientCaps = CapabilityFlags.CLIENT_LONG_PASSWORD | CapabilityFlags.CLIENT_LONG_FLAG |
CapabilityFlags.CLIENT_CONNECT_WITH_DB | CapabilityFlags.CLIENT_PROTOCOL_41 | CapabilityFlags.CLIENT_SECURE_CONNECTION | CapabilityFlags.CLIENT_SESSION_TRACK;

struct ConnectionStatus
{
    ulong affected;
    ulong matched;
    ulong changed;
    ulong lastInsertId;
    ushort flags;
    ushort error;
    ushort warnings;
}

struct ConnectionSettings
{
    this(const(char)[] connectionString)
    {
        auto remaining = connectionString;

        auto indexValue = remaining.indexOf("=");
        while (!remaining.empty) {
            auto indexValueEnd = remaining.indexOf(";", indexValue);
            if (indexValueEnd <= 0)
                indexValueEnd = remaining.length;

            auto name = strip(remaining[0..indexValue]);
            auto value = strip(remaining[indexValue+1..indexValueEnd]);

            switch (name) {
                case "host":
                    host = value;
                    break;
                case "user":
                    user = value;
                    break;
                case "pwd":
                    pwd = value;
                    break;
                case "db":
                    db = value;
                    break;
                case "port":
                    port = to!ushort(value);
                    break;
                default:
                    throw new MySQLException(format("Bad connection string: %s", connectionString));
            }

            if (indexValueEnd == remaining.length)
                return;

            remaining = remaining[indexValueEnd+1..$];
            indexValue = remaining.indexOf("=");
        }

        throw new MySQLException(format("Bad connection string: %s", connectionString));
    }

    CapabilityFlags caps = DefaultClientCaps;

    const(char)[] host;
    const(char)[] user;
    const(char)[] pwd;
    const(char)[] db;
    ushort port = 3306;
}

private struct ServerInfo
{
    const(char)[] versionString;
    ubyte protocol;
    ubyte charSet;
    ushort status;
    uint connection;
    uint caps;
}

struct PreparedStatement
{
package:

    uint id;
    uint params;
}

class Connection
{
    this(string connectionString)
    {
        this(connectionString, DefaultClientCaps);
    }

    this(string connectionString, CapabilityFlags caps = DefaultClientCaps)
    {
        settings_ = ConnectionSettings(connectionString);
        settings_.caps = caps | CapabilityFlags.CLIENT_LONG_PASSWORD | CapabilityFlags.CLIENT_PROTOCOL_41;

        connect();
    }

    this(const(char)[] host, const(char)[] user, const(char)[] pwd, const(char)[] db, ushort port = 3306)
    {
        this(host, user, pwd, db, port, DefaultClientCaps);
    }

    this(const(char)[] host, const(char)[] user, const(char)[] pwd, const(char)[] db, ushort port = 3306, CapabilityFlags caps = DefaultClientCaps)
    {
        settings_.host = host;
        settings_.user = user;
        settings_.pwd = pwd;
        settings_.db = db;
        settings_.port = port;
        settings_.caps = caps | CapabilityFlags.CLIENT_LONG_PASSWORD | CapabilityFlags.CLIENT_PROTOCOL_41;

        connect();
    }

    void use(string File = __FILE__, size_t Line = __LINE__)(const(char)[] db)
    {
        send(Commands.COM_INIT_DB, db);
        eatStatus!(File, Line)(retrieve());

        if ((caps_ & CapabilityFlags.CLIENT_SESSION_TRACK) == 0)
        {
            schema_.length = db.length;
            schema_[] = db[];
        }
    }

    void ping(string File = __FILE__, size_t Line = __LINE__)()
    {
        send(Commands.COM_PING);
        eatStatus!(File, Line)(retrieve());
    }

    void refresh(string File = __FILE__, size_t Line = __LINE__)()
    {
        send(Commands.COM_REFRESH);
        eatStatus!(File, Line)(retrieve());
    }

    void reset(string File = __FILE__, size_t Line = __LINE__)()
    {
        send(Commands.COM_RESET_CONNECTION);
        eatStatus!(File, Line)(retrieve());
    }

    const(char)[] statistics()
    {
        send(Commands.COM_STATISTICS);

        auto answer = retrieve();
        return answer.eat!(const(char)[])(answer.remaining);
    }

    const(char)[] schema() const
    {
        return schema_;
    }

    ConnectionSettings settings() const
    {
        return settings_;
    }

    auto prepare(string File = __FILE__, size_t Line = __LINE__)(const(char)[] sql)
    {
        if (allowClientPreparedCache_ && (sql in clientPreparedCaches))
        {
            return clientPreparedCaches[sql];
        }

        send(Commands.COM_STMT_PREPARE, sql);

        auto answer = retrieve();

        if (answer.peek!ubyte != StatusPackets.OK_Packet)
            eatStatus!(File, Line)(answer);

        answer.expect!ubyte(0);

        auto id = answer.eat!uint;
        auto columns = answer.eat!ushort;
        auto params = answer.eat!ushort;
        answer.expect!ubyte(0);

        auto warnings = answer.eat!ushort;

        if (params)
        {
            foreach (i; 0..params)
                skipColumnDef(retrieve(), Commands.COM_STMT_PREPARE);

            eatEOF(retrieve());
        }

        if (columns)
        {
            foreach (i; 0..columns)
                skipColumnDef(retrieve(), Commands.COM_STMT_PREPARE);

            eatEOF(retrieve());
        }

        PreparedStatement stmt = PreparedStatement(id, params);
        if (allowClientPreparedCache_)
        {
            clientPreparedCaches[sql] = stmt;
        }

        return stmt;
    }

    void executeNoPrepare(string File = __FILE__, size_t Line = __LINE__, Args...)(const(char)[] sql, Args args)
    {
        query!(File, Line)(sql, args);
    }

    void execute(string File = __FILE__, size_t Line = __LINE__, Args...)(const(char)[] sql, Args args)
    {
        //scope(failure) close_();

        auto id = prepare!(File, Line)(sql);
        execute!(File, Line)(id, args);
        //closePreparedStatement(id);
    }

    void set(T, string File = __FILE__, size_t Line = __LINE__)(const(char)[] variable, T value)
    {
        query!(File, Line)("set session ?=?", MySQLFragment(variable), value);
    }

    const(char)[] get(string File = __FILE__, size_t Line = __LINE__)(const(char)[] variable)
    {
        const(char)[] result;
        query!(File, Line)("show session variables like ?", variable, (MySQLRow row) {
            result = row[1].peek!(const(char)[]).dup;
        });

        return result;
    }

    void startTransaction(string File = __FILE__, size_t Line = __LINE__)()
    {
        if (inTransaction)
            throw new MySQLErrorException("MySQL does not support nested transactions - commit or rollback before starting a new transaction", File, Line);

        query!(File, Line)("start transaction");

        assert(inTransaction);
    }

    void commit(string File = __FILE__, size_t Line = __LINE__)()
    {
        if (!inTransaction)
            throw new MySQLErrorException("No active transaction", File, Line);

        query!(File, Line)("commit");

        assert(!inTransaction);
    }

    void rollback(string File = __FILE__, size_t Line = __LINE__)()
    {
        if (connected)
        {
            if ((status_.flags & StatusFlags.SERVER_STATUS_IN_TRANS) == 0)
                throw new MySQLErrorException("No active transaction", File, Line);

            query!(File, Line)("rollback");

            assert(!inTransaction);
        }
    }

    @property bool inTransaction() const
    {
        return connected && (status_.flags & StatusFlags.SERVER_STATUS_IN_TRANS);
    }

    void execute(string File = __FILE__, size_t Line = __LINE__, Args...)(PreparedStatement stmt, Args args)
    {
        //scope(failure) close_();

        ensureConnected();

        seq_ = 0;
        auto packet = OutputPacket(&out_);
        packet.put!ubyte(Commands.COM_STMT_EXECUTE);
        packet.put!uint(stmt.id);
        packet.put!ubyte(Cursors.CURSOR_TYPE_READ_ONLY);
        packet.put!uint(1);

        static if (args.length == 0)
        {
            enum shouldDiscard = true;
        }
        else
        {
            enum shouldDiscard = !isCallable!(args[args.length - 1]);
        }

        enum argCount = shouldDiscard ? args.length : (args.length - 1);

        if (!argCount && stmt.params)
            throw new MySQLErrorException(format("Wrong number of parameters for query. Got 0 but expected %d.", stmt.params), File, Line);

        static if (argCount)
        {
            enum NullsCapacity = 128; // must be power of 2
            ubyte[NullsCapacity >> 3] nulls;
            size_t bitsOut;
            size_t indexArg;

            foreach(i, arg; args[0..argCount])
            {
                const auto index = (indexArg >> 3) & (NullsCapacity - 1);
                const auto bit = indexArg & 7;

                static if (is(typeof(arg) == typeof(null)))
                {
                    nulls[index] = nulls[index] | (1 << bit);
                    ++indexArg;
                }
                else static if (is(Unqual!(typeof(arg)) == MySQLValue))
                {
                    if (arg.isNull)
                        nulls[index] = nulls[index] | (1 << bit);
                    ++indexArg;
                }
                else static if (isArray!(typeof(arg)) && !isSomeString!(typeof(arg)))
                {
                    indexArg += arg.length;
                }
                else
                {
                    ++indexArg;
                }

                auto finishing = (i == argCount - 1);
                auto remaining = indexArg - bitsOut;

                if (finishing || (remaining >= NullsCapacity))
                {
                    while (remaining)
                    {
                        auto bits = min(remaining, NullsCapacity);

                        packet.put(nulls[0..(bits + 7) >> 3]);
                        bitsOut += bits;
                        nulls[] = 0;

                        remaining = (indexArg - bitsOut);
                        if (!remaining || (!finishing && (remaining < NullsCapacity)))
                            break;
                    }
                }
            }
            packet.put!ubyte(1);

            if (indexArg != stmt.params)
                throw new MySQLErrorException(format("Wrong number of parameters for query. Got %d but expected %d.", indexArg, stmt.params), File, Line);

            foreach (arg; args[0..argCount])
            {
                static if (is(typeof(arg) == enum))
                {
                    putValueType(packet, cast(OriginalType!(Unqual!(typeof(arg))))arg);
                }
                else
                {
                    putValueType(packet, arg);
                }
            }

            foreach (arg; args[0..argCount])
            {
                static if (!is(typeof(arg) == typeof(null)))
                {
                    static if (is(typeof(arg) == enum))
                    {
                        putValue(packet, cast(OriginalType!(Unqual!(typeof(arg))))arg);
                    }
                    else
                    {
                        putValue(packet, arg);
                    }
                }
            }
        }

        packet.finalize(seq_);
        ++seq_;

        socket_.write(packet.get());

        auto answer = retrieve();
        if (isStatus(answer))
        {
            eatStatus!(File, Line)(answer);
        }
        else
        {
            static if (!shouldDiscard)
            {
                resultSet!(File, Line)(answer, stmt.id, Commands.COM_STMT_EXECUTE, args[args.length - 1]);
            }
            else
            {
                discardAll(answer, Commands.COM_STMT_EXECUTE);
            }
        }
    }

    void closePreparedStatement(PreparedStatement stmt)
    {
        uint[1] data = [ stmt.id ];
        send(Commands.COM_STMT_CLOSE, data);
    }

    @property ulong lastInsertId() const
    {
        return status_.lastInsertId;
    }

    @property ulong affected() const {
        return cast(size_t)status_.affected;
    }

    @property ulong matched() const
    {
        return cast(size_t)status_.matched;
    }

    @property ulong changed() const
    {
        return cast(size_t)status_.changed;
    }

    @property size_t warnings() const
    {
        return status_.warnings;
    }

    @property size_t error() const
    {
        return status_.error;
    }

    @property const(char)[] status() const
    {
        return info_;
    }

    @property bool connected() const
    {
        return socket_.connected;
    }

    void close()
    {
        socket_.close();
    }

    void reuse()
    {
        ensureConnected();

        if (inTransaction)
            rollback;
        if (settings_.db.length && (settings_.db != schema_))
            use(settings_.db);
    }

    @property void trace(bool enable)
    {
        trace_ = enable;
    }

    @property bool trace()
    {
        return trace_;
    }

    @property void allowClientPreparedCache(bool enable)
    {
        allowClientPreparedCache_ = enable;
    }

    @property bool allowClientPreparedCache()
    {
        return allowClientPreparedCache_;
    }

package:

    bool busy_ = false;

    @property bool busy()
    {
        return busy_;
    }

    @property void busy(bool value)
    {
        busy_ = value;
    }

private:

    void close_()
    {
        close();
    }

    void query(string File, size_t Line, Args...)(const(char)[] sql, Args args)
    {
        //scope(failure) close_();

        static if (args.length == 0)
        {
            enum shouldDiscard = true;
        }
        else
        {
            enum shouldDiscard = !isCallable!(args[args.length - 1]);
        }

        enum argCount = shouldDiscard ? args.length : (args.length - 1);

        static if (argCount)
        {
            auto querySQL =  prepareSQL!(File, Line)(sql, args[0..argCount]);
        }
        else
        {
            auto querySQL =  sql;
        }

        version(development)
        {
            import std.stdio : stderr, writefln;
            if (trace_)
                stderr.writefln("%s:%s %s", File, Line, querySQL);
        }

        send(Commands.COM_QUERY, querySQL);

        auto answer = retrieve();
        if (isStatus(answer))
        {
            eatStatus!(File, Line)(answer);
        }
        else
        {
            static if (!shouldDiscard)
            {
                resultSetText!(File, Line)(answer, Commands.COM_QUERY, args[args.length - 1]);
            }
            else
            {
                discardAll(answer, Commands.COM_QUERY);
            }
        }
    }

    void connect()
    {
        socket_.connect(settings_.host, settings_.port);

        seq_ = 0;
        eatHandshake(retrieve());
        clientPreparedCaches.clear();
    }

    void send(T)(Commands cmd, T[] data)
    {
        send(cmd, cast(ubyte*)data.ptr, data.length * T.sizeof);
    }

    void send(Commands cmd, ubyte* data = null, size_t length = 0)
    {
        ensureConnected();

        seq_ = 0;
        auto header = OutputPacket(&out_);
        header.put!ubyte(cmd);
        header.finalize(seq_, length);
        ++seq_;

        socket_.write(header.get());
        if (length)
            socket_.write(data[0..length]);
    }

    void ensureConnected()
    {
        if (!socket_.connected)
            connect();
    }

    bool isStatus(InputPacket packet)
    {
        auto id = packet.peek!ubyte;
        switch (id)
        {
        case StatusPackets.ERR_Packet:
        case StatusPackets.OK_Packet:
            return true;
        default:
            return false;
        }
    }

    void check(string File, size_t Line)(InputPacket packet, bool smallError = false)
    {
        auto id = packet.peek!ubyte;
        switch (id)
        {
        case StatusPackets.ERR_Packet:
        case StatusPackets.OK_Packet:
            eatStatus!(File, Line)(packet, smallError);
            break;
        default:
            break;
        }
    }

    InputPacket retrieve()
    {
        //scope(failure) close_();

        ubyte[4] header;
        socket_.read(header);

        auto len = header[0] | (header[1] << 8) | (header[2] << 16);
        auto seq = header[3];

        if (seq != seq_)
            throw new MySQLConnectionException("Out of order packet received");

        ++seq_;

        in_.length = len;
        socket_.read(in_);

        if (in_.length != len)
            throw new MySQLConnectionException("Wrong number of bytes read");

        return InputPacket(&in_);
    }

    void eatHandshake(InputPacket packet)
    {
        //scope(failure) close_();

        check!(__FILE__, __LINE__)(packet, true);

        server_.protocol = packet.eat!ubyte;
        server_.versionString = packet.eat!(const(char)[])(packet.countUntil(0, true)).dup;
        packet.skip(1);

        server_.connection = packet.eat!uint;

        const auto authLengthStart = 8;
        size_t authLength = authLengthStart;

        ubyte[256] auth;
        auth[0..authLength] = packet.eat!(ubyte[])(authLength);

        packet.expect!ubyte(0);

        server_.caps = packet.eat!ushort;

        if (!packet.empty)
        {
            server_.charSet = packet.eat!ubyte;
            server_.status = packet.eat!ushort;
            server_.caps |= packet.eat!ushort << 16;
            server_.caps |= CapabilityFlags.CLIENT_LONG_PASSWORD;

            if ((server_.caps & CapabilityFlags.CLIENT_PROTOCOL_41) == 0)
                throw new MySQLProtocolException("Server doesn't support protocol v4.1");

            if (server_.caps & CapabilityFlags.CLIENT_SECURE_CONNECTION)
            {
                packet.skip(1);
            }
            else
            {
                packet.expect!ubyte(0);
            }

            packet.skip(10);

            authLength += packet.countUntil(0, true);
            if (authLength > auth.length)
                throw new MySQLConnectionException("Bad packet format");

            auth[authLengthStart..authLength] = packet.eat!(ubyte[])(authLength - authLengthStart);

            packet.expect!ubyte(0);
        }

        ubyte[20] token;
        {
            import std.digest.sha : sha1Of;

            auto pass = sha1Of(cast(const(ubyte)[])settings_.pwd);
            token = sha1Of(auth[0..authLength], sha1Of(pass));

            foreach (i; 0..20)
                token[i] = token[i] ^ pass[i];
        }

        caps_ = cast(CapabilityFlags)(settings_.caps & server_.caps);
        auto reply = OutputPacket(&out_);

        reply.reserve(64 + settings_.user.length + settings_.pwd.length + settings_.db.length);

        reply.put!uint(caps_);
        reply.put!uint(1);
        reply.put!ubyte(45);
        reply.fill(0, 23);

        reply.put(settings_.user);
        reply.put!ubyte(0);

        if (settings_.pwd.length)
        {
            if (caps_ & CapabilityFlags.CLIENT_SECURE_CONNECTION)
            {
                reply.put!ubyte(token.length);
                reply.put(token);
            }
            else
            {
                reply.put(token);
                reply.put!ubyte(0);
            }
        }
        else
        {
            reply.put!ubyte(0);
        }

        if ((settings_.db.length || schema_.length) && (caps_ & CapabilityFlags.CLIENT_CONNECT_WITH_DB))
        {
            if (schema_.length)
            {
                reply.put(schema_);
            }
            else
            {
                reply.put(settings_.db);

                schema_.length = settings_.db.length;
                schema_[] = settings_.db[];
            }
        }

        reply.put!ubyte(0);

        reply.finalize(seq_);
        ++seq_;

        socket_.write(reply.get());

        eatStatus!(__FILE__, __LINE__)(retrieve());
    }

    void eatStatus(string File, size_t Line)(InputPacket packet, bool smallError = false)
    {
        auto id = packet.eat!ubyte;

        switch (id)
        {
        case StatusPackets.OK_Packet:
            status_.matched = 0;
            status_.changed = 0;
            status_.affected = packet.eatLenEnc();
            status_.lastInsertId = packet.eatLenEnc();
            status_.flags = packet.eat!ushort;
            if (caps_ & CapabilityFlags.CLIENT_PROTOCOL_41)
            {
                status_.warnings = packet.eat!ushort;
            }
            status_.error = 0;
            info([]);

            if (caps_ & CapabilityFlags.CLIENT_SESSION_TRACK)
            {
                if (!packet.empty)
                {
                    info(packet.eat!(const(char)[])(cast(size_t)packet.eatLenEnc()));

                    if (!packet.empty && (status_.flags & StatusFlags.SERVER_SESSION_STATE_CHANGED))
                    {
                        packet.skip(cast(size_t)packet.eatLenEnc());
                    }
                }
            }
            else
            {
				info(packet.eat!(const(char)[])(packet.remaining));
			}

            auto matches = matchFirst(info_, ctRegex!(`\smatched:\s*(\d+)\s+changed:\s*(\d+)`, `i`));
            if (!matches.empty)
            {
				status_.matched = matches[1].to!ulong;
				status_.changed = matches[2].to!ulong;
			}

            break;
        case StatusPackets.EOF_Packet:
            status_.affected = 0;
            status_.changed = 0;
            status_.matched = 0;
            status_.error = 0;
            status_.warnings = packet.eat!ushort;
            status_.flags = packet.eat!ushort;
            info([]);

            break;
        case StatusPackets.ERR_Packet:
            status_.affected = 0;
            status_.changed = 0;
            status_.matched = 0;
            //status_.flags = 0;
            status_.flags &= StatusFlags.SERVER_STATUS_IN_TRANS;
            status_.warnings = 0;
            status_.error = packet.eat!ushort;
            if (!smallError)
                packet.skip(6);
            info(packet.eat!(const(char)[])(packet.remaining));

            switch(status_.error) {
            case ErrorCodes.ER_DUP_ENTRY_WITH_KEY_NAME:
            case ErrorCodes.ER_DUP_ENTRY:
                throw new MySQLDuplicateEntryException(info_.idup, File, Line);
            case ErrorCodes.ER_DATA_TOO_LONG_FOR_COL:
                throw new MySQLDataTooLongException(info_.idup, File, Line);
            case ErrorCodes.ER_DEADLOCK_FOUND:
                throw new MySQLDeadlockFoundException(info_.idup, File, Line);
            default:
                version(development)
                {
                    // On dev show the query together with the error message
                    throw new MySQLErrorException(format("[err:%s] %s - %s", status_.error, info_, sql_.data), File, Line);
                }
                else
                {
                    throw new MySQLErrorException(format("[err:%s] %s", status_.error, info_), File, Line);
                }
            }
        default:
            throw new MySQLProtocolException("Unexpected packet format");
        }
    }

    void info(const(char)[] value)
    {
        info_.length = value.length;
        info_[0..$] = value;
    }

    void skipColumnDef(InputPacket packet, Commands cmd)
    {
        packet.skip(cast(size_t)packet.eatLenEnc());    // catalog
        packet.skip(cast(size_t)packet.eatLenEnc());    // schema
        packet.skip(cast(size_t)packet.eatLenEnc());    // table
        packet.skip(cast(size_t)packet.eatLenEnc());    // original_table
        packet.skip(cast(size_t)packet.eatLenEnc());    // name
        packet.skip(cast(size_t)packet.eatLenEnc());    // original_name
        packet.skipLenEnc();                            // next_length
        packet.skip(10); // 2 + 4 + 1 + 2 + 1            // charset, length, type, flags, decimals
        packet.expect!ushort(0);

        if (cmd == Commands.COM_FIELD_LIST)
            packet.skip(cast(size_t)packet.eatLenEnc());// default values
    }

    void columnDef(InputPacket packet, Commands cmd, ref MySQLColumn def)
    {
        packet.skip(cast(size_t)packet.eatLenEnc());    // catalog
        packet.skip(cast(size_t)packet.eatLenEnc());    // schema
        packet.skip(cast(size_t)packet.eatLenEnc());    // table
        packet.skip(cast(size_t)packet.eatLenEnc());    // original_table
        auto len = cast(size_t)packet.eatLenEnc();
        columns_ ~= packet.eat!(const(char)[])(len);
        def.name = columns_[$-len..$];
        packet.skip(cast(size_t)packet.eatLenEnc());    // original_name
        packet.skipLenEnc();                            // next_length
        packet.skip(2);                                    // charset
        def.length = packet.eat!uint;
        def.type = cast(ColumnTypes)packet.eat!ubyte;
        def.flags = packet.eat!ushort;
        def.decimals = packet.eat!ubyte;

        packet.expect!ushort(0);

        if (cmd == Commands.COM_FIELD_LIST)
            packet.skip(cast(size_t)packet.eatLenEnc());// default values
    }

    void columnDefs(size_t count, Commands cmd, ref MySQLColumn[] defs)
    {
        defs.length = count;
        foreach (i; 0..count)
            columnDef(retrieve(), cmd, defs[i]);
    }

    bool callHandler(RowHandler)(RowHandler handler, size_t, MySQLHeader, MySQLRow row) if ((ParameterTypeTuple!(RowHandler).length == 1) && is(ParameterTypeTuple!(RowHandler)[0] == MySQLRow))
    {
        static if (is(ReturnType!(RowHandler) == void))
        {
            handler(row);
            return true;
        }
        else
        {
            return handler(row); // return type must be bool
        }
    }

    bool callHandler(RowHandler)(RowHandler handler, size_t i, MySQLHeader, MySQLRow row) if ((ParameterTypeTuple!(RowHandler).length == 2) && isNumeric!(ParameterTypeTuple!(RowHandler)[0]) && is(ParameterTypeTuple!(RowHandler)[1] == MySQLRow))
    {
        static if (is(ReturnType!(RowHandler) == void))
        {
            handler(cast(ParameterTypeTuple!(RowHandler)[0])i, row);
            return true;
        }
        else
        {
            return handler(cast(ParameterTypeTuple!(RowHandler)[0])i, row); // return type must be bool
        }
    }

    bool callHandler(RowHandler)(RowHandler handler, size_t, MySQLHeader header, MySQLRow row) if ((ParameterTypeTuple!(RowHandler).length == 2) && is(ParameterTypeTuple!(RowHandler)[0] == MySQLHeader) && is(ParameterTypeTuple!(RowHandler)[1] == MySQLRow))
    {
        static if (is(ReturnType!(RowHandler) == void))
        {
            handler(header, row);
            return true;
        }
        else
        {
            return handler(header, row); // return type must be bool
        }
    }

    bool callHandler(RowHandler)(RowHandler handler, size_t i, MySQLHeader header, MySQLRow row) if ((ParameterTypeTuple!(RowHandler).length == 3) && isNumeric!(ParameterTypeTuple!(RowHandler)[0]) && is(ParameterTypeTuple!(RowHandler)[1] == MySQLHeader) && is(ParameterTypeTuple!(RowHandler)[2] == MySQLRow))
    {
        static if (is(ReturnType!(RowHandler) == void))
        {
            handler(i, header, row);
            return true;
        }
        else
        {
            return handler(i, header, row); // return type must be bool
        }
    }

    void resultSetRow(InputPacket packet, MySQLHeader header, ref MySQLRow row)
    {
        assert(row.columns.length == header.length);

        packet.expect!ubyte(0);
        auto nulls = packet.eat!(ubyte[])((header.length + 2 + 7) >> 3);
        foreach (i, ref column; header)
        {
            const auto index = (i + 2) >> 3; // bit offset of 2
            const auto bit = (i + 2) & 7;

            if ((nulls[index] & (1 << bit)) == 0)
            {
                eatValue(packet, column, row.get_(i));
            }
            else
            {
                auto signed = (column.flags & FieldFlags.UNSIGNED_FLAG) == 0;
                row.get_(i) = MySQLValue(column.name, ColumnTypes.MYSQL_TYPE_NULL, signed, null, 0);
            }
        }
        assert(packet.empty);
    }

    void resultSet(string File = __FILE__, size_t Line = __LINE__, RowHandler)(InputPacket packet, uint stmt, Commands cmd, RowHandler handler)
    {
        columns_.length = 0;

        auto columns = cast(size_t)packet.eatLenEnc();
        columnDefs(columns, cmd, header_);
        row_.header_(header_);

        auto status = retrieve();
        if (status.peek!ubyte == StatusPackets.ERR_Packet)
            eatStatus!(File, Line)(status);

        size_t index;
        auto statusFlags = eatEOF(status);
        if (statusFlags & StatusFlags.SERVER_STATUS_CURSOR_EXISTS)
        {
            uint[2] data = [ stmt, 4096 ]; // todo: make setting - rows per fetch
            while (statusFlags & (StatusFlags.SERVER_STATUS_CURSOR_EXISTS | StatusFlags.SERVER_MORE_RESULTS_EXISTS))
            {
                send(Commands.COM_STMT_FETCH, data);

                auto answer = retrieve();
                if (answer.peek!ubyte == StatusPackets.ERR_Packet)
                    eatStatus!(File, Line)(answer);

                auto row = answer.empty ? retrieve() : answer;
                while (true)
                {
                    if (row.peek!ubyte == StatusPackets.EOF_Packet)
                    {
                        statusFlags = eatEOF(row);
                        break;
                    }

                    resultSetRow(row, header_, row_);
                    if (!callHandler(handler, index++, header_, row_))
                    {
                        discardUntilEOF(retrieve());
                        statusFlags = 0;
                        break;
                    }
                    row = retrieve();
                }
            }
        }
        else
        {
            while (true)
            {
                auto row = retrieve();
                if (row.peek!ubyte == StatusPackets.EOF_Packet)
                {
                    eatEOF(row);
                    break;
                }

                resultSetRow(row, header_, row_);
                if (!callHandler(handler, index++, header_, row_))
                {
                    discardUntilEOF(retrieve());
                    break;
                }
            }
        }
    }

    void resultSetRowText(InputPacket packet, MySQLHeader header, ref MySQLRow row)
    {
        assert(row.columns.length == header.length);

        foreach(i, ref column; header)
        {
            if (packet.peek!ubyte != 0xfb)
            {
                eatValueText(packet, column, row.get_(i));
            }
            else
            {
                packet.skip(1);
                auto signed = (column.flags & FieldFlags.UNSIGNED_FLAG) == 0;
                row.get_(i) = MySQLValue(column.name, ColumnTypes.MYSQL_TYPE_NULL, signed, null, 0);
            }
        }
        assert(packet.empty);
    }

    void resultSetText(string File, size_t Line, RowHandler)(InputPacket packet, Commands cmd, RowHandler handler)
    {
        columns_.length = 0;

        auto columns = cast(size_t)packet.eatLenEnc();
        columnDefs(columns, cmd, header_);
        row_.header_(header_);

        eatEOF(retrieve());

        size_t index;
        while (true) {
            auto row = retrieve();
            if (row.peek!ubyte == StatusPackets.EOF_Packet)
            {
                eatEOF(row);
                break;
            } else if (row.peek!ubyte == StatusPackets.ERR_Packet)
            {
                eatStatus!(File, Line)(row);
                break;
            }

            resultSetRowText(row, header_, row_);
            if (!callHandler(handler, index++, header_, row_))
            {
                discardUntilEOF(retrieve());
                break;
            }
        }
    }

    void discardAll(InputPacket packet, Commands cmd)
    {
        auto columns = cast(size_t)packet.eatLenEnc();
        columnDefs(columns, cmd, header_);

        auto statusFlags = eatEOF(retrieve());
        if ((statusFlags & StatusFlags.SERVER_STATUS_CURSOR_EXISTS) == 0)
        {
            while (true)
            {
                auto row = retrieve();
                if (row.peek!ubyte == StatusPackets.EOF_Packet)
                {
                    eatEOF(row);
                    break;
                }
            }
        }
    }

    void discardUntilEOF(InputPacket packet)
    {
        while (true)
        {
            if (packet.peek!ubyte == StatusPackets.EOF_Packet)
            {
                eatEOF(packet);
                break;
            }
            packet = retrieve();
        }
    }

    auto eatEOF(InputPacket packet)
    {
        auto id = packet.eat!ubyte;
        if (id != StatusPackets.EOF_Packet)
            throw new MySQLProtocolException("Unexpected packet format");

        status_.error = 0;
        status_.warnings = packet.eat!ushort();
        status_.flags = packet.eat!ushort();
        info([]);

        return status_.flags;
    }

    auto prepareSQL(string File, size_t Line, Args...)(const(char)[] sql, Args args)
    {
        auto estimated = sql.length;
        size_t argCount;

        foreach(i, arg; args)
        {
            static if (is(typeof(arg) == typeof(null)))
            {
                ++argCount;
                estimated += 4;
            }
            else static if (is(Unqual!(typeof(arg)) == MySQLValue))
            {
                ++argCount;
                final switch(arg.type) with (ColumnTypes)
                {
                case MYSQL_TYPE_NULL:
                    estimated += 4;
                    break;
                case MYSQL_TYPE_TINY:
                    estimated += 4;
                    break;
                case MYSQL_TYPE_YEAR:
                case MYSQL_TYPE_SHORT:
                    estimated += 6;
                    break;
                case MYSQL_TYPE_INT24:
                case MYSQL_TYPE_LONG:
                    estimated += 6;
                    break;
                case MYSQL_TYPE_LONGLONG:
                    estimated += 8;
                    break;
                case MYSQL_TYPE_FLOAT:
                    estimated += 8;
                    break;
                case MYSQL_TYPE_DOUBLE:
                    estimated += 8;
                    break;
                case MYSQL_TYPE_SET:
                case MYSQL_TYPE_ENUM:
                case MYSQL_TYPE_VARCHAR:
                case MYSQL_TYPE_VAR_STRING:
                case MYSQL_TYPE_STRING:
                case MYSQL_TYPE_JSON:
                case MYSQL_TYPE_NEWDECIMAL:
                case MYSQL_TYPE_DECIMAL:
                case MYSQL_TYPE_TINY_BLOB:
                case MYSQL_TYPE_MEDIUM_BLOB:
                case MYSQL_TYPE_LONG_BLOB:
                case MYSQL_TYPE_BLOB:
                case MYSQL_TYPE_BIT:
                case MYSQL_TYPE_GEOMETRY:
                    estimated += 2 + arg.peek!(const(char)[]).length;
                    break;
                case MYSQL_TYPE_TIME:
                case MYSQL_TYPE_TIME2:
                    estimated += 18;
                    break;
                case MYSQL_TYPE_DATE:
                case MYSQL_TYPE_NEWDATE:
                case MYSQL_TYPE_DATETIME:
                case MYSQL_TYPE_DATETIME2:
                case MYSQL_TYPE_TIMESTAMP:
                case MYSQL_TYPE_TIMESTAMP2:
                    estimated += 20;
                    break;
                }
            }
            else static if (isArray!(typeof(arg)) && !isSomeString!(typeof(arg)))
            {
                argCount += arg.length;
                estimated += arg.length * 6;
            }
            else static if (isSomeString!(typeof(arg)) || is(Unqual!(typeof(arg)) == MySQLRawString) || is(Unqual!(typeof(arg)) == MySQLFragment) || is(Unqual!(typeof(arg)) == MySQLBinary))
            {
                ++argCount;
                estimated += 2 + arg.length;
            }
            else
            {
                ++argCount;
                estimated += 6;
            }
        }

        sql_.clear;
        sql_.reserve(max(8192, estimated));

        alias AppendFunc = bool function(ref Appender!(char[]), ref const(char)[] sql, ref size_t, const(void)*) @safe pure nothrow;
        AppendFunc[Args.length] funcs;
        const(void)*[Args.length] addrs;

        foreach (i, Arg; Args)
        {
            static if (is(Arg == enum))
            {
                funcs[i] = () @trusted { return cast(AppendFunc)&appendNextValue.appendNextValue!(OriginalType!Arg); }();
                addrs[i] = (ref x) @trusted { return cast(const void*)&x; }(cast(OriginalType!(Unqual!Arg))args[i]);
            }
            else
            {
                funcs[i] = () @trusted { return cast(AppendFunc)&appendNextValue.appendNextValue!(Arg); }();
                addrs[i] = (ref x) @trusted { return cast(const void*)&x; }(args[i]);
            }
        }

        size_t indexArg;
        foreach (i; 0..Args.length)
        {
            if (!funcs[i](sql_, sql, indexArg, addrs[i]))
                throw new MySQLErrorException(format("Wrong number of parameters for query. Got %d but expected %d.", argCount, indexArg), File, Line);
        }

        if (Utils.copyUpToNext(sql_, sql))
        {
            ++indexArg;
            while (Utils.copyUpToNext(sql_, sql))
                ++indexArg;
            throw new MySQLErrorException(format("Wrong number of parameters for query. Got %d but expected %d.", argCount, indexArg), File, Line);
        }

        return sql_.data;
    }

    Socket socket_;
    MySQLHeader header_;
    MySQLRow row_;
    char[] columns_;
    char[] info_;
    char[] schema_;
    ubyte[] in_;
    ubyte[] out_;
    ubyte seq_;
    Appender!(char[]) sql_;

    CapabilityFlags caps_;
    ConnectionStatus status_;
    ConnectionSettings settings_;
    ServerInfo server_;

    // For tracing queries
    bool trace_;

    // For mysql server not support prepared cache.
    bool allowClientPreparedCache_ = true;
    PreparedStatement[string] clientPreparedCaches;
}
