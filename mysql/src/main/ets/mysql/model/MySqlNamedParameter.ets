import { ArkDbError } from '@arkdb/core';
import { MySqlParameter } from './MySqlParameter';

export class MySqlNamedParameter {
  readonly name: string;
  readonly parameter: MySqlParameter;

  constructor(name: string, parameter: MySqlParameter) {
    if (!isMySqlNamedParameterName(name)) {
      throw ArkDbError.validation(
        'MySQL named parameter names must match [A-Za-z_][A-Za-z0-9_]*.');
    }
    if (!(parameter instanceof MySqlParameter)) {
      throw ArkDbError.validation('MySQL named parameter values must be MySqlParameter instances.');
    }
    this.name = name;
    this.parameter = new MySqlParameter(parameter.type, parameter.value);
  }
}

export function isMySqlNamedParameterName(name: string): boolean {
  if (name.length === 0 || !isNamedParameterStart(name.charCodeAt(0))) return false;
  for (let index = 1; index < name.length; index += 1) {
    if (!isNamedParameterPart(name.charCodeAt(index))) return false;
  }
  return true;
}

export function isNamedParameterStart(code: number): boolean {
  return (code >= 0x41 && code <= 0x5a) || code === 0x5f ||
    (code >= 0x61 && code <= 0x7a);
}

export function isNamedParameterPart(code: number): boolean {
  return isNamedParameterStart(code) || (code >= 0x30 && code <= 0x39);
}
