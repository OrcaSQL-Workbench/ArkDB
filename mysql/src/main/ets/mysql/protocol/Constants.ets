/**
 * MySQL/MariaDB client-server protocol constants.
 * Static-member classes (ArkTS-friendly; no namespaces).
 */

/** Client/server capability flags (lower 32 bits). */
export class Capabilities {
  static readonly LONG_PASSWORD = 0x00000001;
  static readonly FOUND_ROWS = 0x00000002;
  static readonly LONG_FLAG = 0x00000004;
  static readonly CONNECT_WITH_DB = 0x00000008;
  static readonly NO_SCHEMA = 0x00000010;
  static readonly COMPRESS = 0x00000020;
  static readonly ODBC = 0x00000040;
  static readonly LOCAL_FILES = 0x00000080;
  static readonly IGNORE_SPACE = 0x00000100;
  static readonly PROTOCOL_41 = 0x00000200;
  static readonly INTERACTIVE = 0x00000400;
  static readonly SSL = 0x00000800;
  static readonly IGNORE_SIGPIPE = 0x00001000;
  static readonly TRANSACTIONS = 0x00002000;
  static readonly RESERVED = 0x00004000;
  static readonly SECURE_CONNECTION = 0x00008000;
  static readonly MULTI_STATEMENTS = 0x00010000;
  static readonly MULTI_RESULTS = 0x00020000;
  static readonly PS_MULTI_RESULTS = 0x00040000;
  static readonly PLUGIN_AUTH = 0x00080000;
  static readonly CONNECT_ATTRS = 0x00100000;
  static readonly PLUGIN_AUTH_LENENC_CLIENT_DATA = 0x00200000;
  static readonly CAN_HANDLE_EXPIRED_PASSWORDS = 0x00400000;
  static readonly SESSION_TRACK = 0x00800000;
  static readonly DEPRECATE_EOF = 0x01000000;
}

/** Protocol commands (first payload byte). */
export class Command {
  static readonly QUIT = 0x01;
  static readonly INIT_DB = 0x02;
  static readonly QUERY = 0x03;
  static readonly PING = 0x0e;
  static readonly STMT_PREPARE = 0x16;
  static readonly STMT_CLOSE = 0x19;
}

/** Generic packet-type sentinels (first payload byte of a response). */
export class PacketType {
  static readonly OK = 0x00;
  static readonly LOCAL_INFILE = 0xfb;
  static readonly EOF = 0xfe;
  static readonly ERR = 0xff;
  static readonly AUTH_MORE_DATA = 0x01;     // in the auth phase
  static readonly AUTH_SWITCH = 0xfe;        // in the auth phase
}

/** Server status flags (from OK/EOF packets). */
export class StatusFlags {
  static readonly IN_TRANS = 0x0001;
  static readonly AUTOCOMMIT = 0x0002;
  static readonly MORE_RESULTS_EXISTS = 0x0008;
  static readonly NO_GOOD_INDEX_USED = 0x0010;
  static readonly CURSOR_EXISTS = 0x0040;
  static readonly LAST_ROW_SENT = 0x0080;
}

/** MySQL column type codes. */
export class ColumnType {
  static readonly DECIMAL = 0x00;
  static readonly TINY = 0x01;
  static readonly SHORT = 0x02;
  static readonly LONG = 0x03;
  static readonly FLOAT = 0x04;
  static readonly DOUBLE = 0x05;
  static readonly NULL = 0x06;
  static readonly TIMESTAMP = 0x07;
  static readonly LONGLONG = 0x08;
  static readonly INT24 = 0x09;
  static readonly DATE = 0x0a;
  static readonly TIME = 0x0b;
  static readonly DATETIME = 0x0c;
  static readonly YEAR = 0x0d;
  static readonly NEWDATE = 0x0e;
  static readonly VARCHAR = 0x0f;
  static readonly BIT = 0x10;
  static readonly JSON = 0xf5;
  static readonly NEWDECIMAL = 0xf6;
  static readonly ENUM = 0xf7;
  static readonly SET = 0xf8;
  static readonly TINY_BLOB = 0xf9;
  static readonly MEDIUM_BLOB = 0xfa;
  static readonly LONG_BLOB = 0xfb;
  static readonly BLOB = 0xfc;
  static readonly VAR_STRING = 0xfd;
  static readonly STRING = 0xfe;
  static readonly GEOMETRY = 0xff;
}

/** Column definition flags. */
export class FieldFlag {
  static readonly NOT_NULL = 0x0001;
  static readonly PRI_KEY = 0x0002;
  static readonly UNIQUE_KEY = 0x0004;
  static readonly MULTIPLE_KEY = 0x0008;
  static readonly BLOB = 0x0010;
  static readonly UNSIGNED = 0x0020;
  static readonly ZEROFILL = 0x0040;
  static readonly BINARY = 0x0080;
  static readonly ENUM = 0x0100;
  static readonly AUTO_INCREMENT = 0x0200;
  static readonly TIMESTAMP = 0x0400;
  static readonly SET = 0x0800;
}

/** Collation ids we reference directly. */
export class Collation {
  static readonly UTF8MB4_GENERAL_CI = 45;
  static readonly BINARY = 63;
}
