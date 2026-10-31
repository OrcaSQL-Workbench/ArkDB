import { ArkDbError } from '@arkdb/core';
import {
  isNamedParameterPart, isNamedParameterStart
} from '../model/MySqlNamedParameter';

export class CompiledSqlTemplate {
  readonly sql: string;
  readonly parameterNames: string[];

  constructor(sql: string, parameterNames: string[]) {
    this.sql = sql;
    this.parameterNames = parameterNames.slice();
  }
}

enum SqlTemplateState {
  Code,
  SingleQuoted,
  DoubleQuotedString,
  DoubleQuotedIdentifier,
  BacktickQuoted,
  HashComment,
  DashComment,
  BlockComment
}

export class SqlTemplateScanner {
  compile(sql: string, sqlMode: string): CompiledSqlTemplate {
    const ansiQuotes = hasSqlMode(sqlMode, 'ANSI_QUOTES');
    const noBackslashEscapes = hasSqlMode(sqlMode, 'NO_BACKSLASH_ESCAPES');
    const pieces: string[] = [];
    const names: string[] = [];
    let state: SqlTemplateState = SqlTemplateState.Code;
    let segmentStart: number = 0;
    let index: number = 0;

    while (index < sql.length) {
      const code: number = sql.charCodeAt(index);
      if (state === SqlTemplateState.Code) {
        if (code === 0x27) {
          state = SqlTemplateState.SingleQuoted;
          index += 1;
          continue;
        }
        if (code === 0x22) {
          state = ansiQuotes ?
            SqlTemplateState.DoubleQuotedIdentifier : SqlTemplateState.DoubleQuotedString;
          index += 1;
          continue;
        }
        if (code === 0x60) {
          state = SqlTemplateState.BacktickQuoted;
          index += 1;
          continue;
        }
        if (code === 0x23) {
          state = SqlTemplateState.HashComment;
          index += 1;
          continue;
        }
        if (code === 0x2d && sql.charCodeAt(index + 1) === 0x2d &&
          isDashCommentFollower(sql, index + 2)) {
          state = SqlTemplateState.DashComment;
          index += 2;
          continue;
        }
        if (code === 0x2f && sql.charCodeAt(index + 1) === 0x2a) {
          rejectExecutableComment(sql, index);
          state = SqlTemplateState.BlockComment;
          index += 2;
          continue;
        }
        if (code === 0x3f) {
          throw ArkDbError.validation(
            'Named SQL templates cannot mix positional and named parameters.');
        }
        if (code === 0x3a && isNamedParameterStart(sql.charCodeAt(index + 1))) {
          let end: number = index + 2;
          while (end < sql.length && isNamedParameterPart(sql.charCodeAt(end))) end += 1;
          pieces.push(sql.substring(segmentStart, index));
          pieces.push('?');
          names.push(sql.substring(index + 1, end));
          segmentStart = end;
          index = end;
          continue;
        }
        index += 1;
        continue;
      }

      if (state === SqlTemplateState.HashComment || state === SqlTemplateState.DashComment) {
        if (code === 0x0a || code === 0x0d) state = SqlTemplateState.Code;
        index += 1;
        continue;
      }

      if (state === SqlTemplateState.BlockComment) {
        if (code === 0x2a && sql.charCodeAt(index + 1) === 0x2f) {
          state = SqlTemplateState.Code;
          index += 2;
        } else {
          index += 1;
        }
        continue;
      }

      const delimiter: number = quoteDelimiter(state);
      if (!noBackslashEscapes && isStringState(state) &&
        code === 0x5c && index + 1 < sql.length) {
        index += 2;
        continue;
      }
      if (code === delimiter) {
        if (sql.charCodeAt(index + 1) === delimiter) {
          index += 2;
        } else {
          state = SqlTemplateState.Code;
          index += 1;
        }
        continue;
      }
      index += 1;
    }

    pieces.push(sql.substring(segmentStart));
    return new CompiledSqlTemplate(pieces.join(''), names);
  }
}

function quoteDelimiter(state: SqlTemplateState): number {
  if (state === SqlTemplateState.SingleQuoted) return 0x27;
  if (state === SqlTemplateState.BacktickQuoted) return 0x60;
  return 0x22;
}

function isStringState(state: SqlTemplateState): boolean {
  return state === SqlTemplateState.SingleQuoted ||
    state === SqlTemplateState.DoubleQuotedString;
}

function hasSqlMode(sqlMode: string, expected: string): boolean {
  const modes: string[] = sqlMode.split(',');
  for (const mode of modes) {
    if (mode.trim().toUpperCase() === expected) return true;
  }
  return false;
}

function isDashCommentFollower(sql: string, index: number): boolean {
  if (index >= sql.length) return false;
  const code: number = sql.charCodeAt(index);
  return code <= 0x20 || code === 0x7f;
}

function rejectExecutableComment(sql: string, index: number): void {
  const marker: number = sql.charCodeAt(index + 2);
  if (marker === 0x21 || marker === 0x2b ||
    ((marker === 0x4d || marker === 0x6d) && sql.charCodeAt(index + 3) === 0x21)) {
    throw ArkDbError.validation('Executable comments are not supported in named SQL templates.');
  }
}
