import { ArkDbError } from '@arkdb/core';
import { MySqlParameter, MySqlParameterType } from './MySqlParameter';
import { MySqlQueryResult, MySqlValue } from './MySqlQueryResult';

export enum MySqlParameterDirection {
  In = 'in',
  Out = 'out',
  InOut = 'inout'
}

export class MySqlProcedureArgument {
  readonly direction: MySqlParameterDirection;
  readonly parameter: MySqlParameter;

  constructor(direction: MySqlParameterDirection, parameter: MySqlParameter) {
    if (direction !== MySqlParameterDirection.In &&
      direction !== MySqlParameterDirection.Out &&
      direction !== MySqlParameterDirection.InOut) {
      throw ArkDbError.validation('Unknown MySQL procedure parameter direction.');
    }
    if (!(parameter instanceof MySqlParameter)) {
      throw ArkDbError.validation(
        'MySQL procedure arguments must contain MySqlParameter values.');
    }
    if (direction !== MySqlParameterDirection.In &&
      parameter.type === MySqlParameterType.Null) {
      throw ArkDbError.validation(
        'MySQL OUT and INOUT parameters require an explicit non-Null type.');
    }
    this.direction = direction;
    this.parameter = new MySqlParameter(parameter.type,
      direction === MySqlParameterDirection.Out ? null : parameter.value);
  }
}

export class MySqlProcedureResult {
  readonly results: MySqlQueryResult[];
  readonly outResultIndex: number;
  readonly outValues: MySqlValue[];

  constructor(results: MySqlQueryResult[] = [], outResultIndex: number = -1,
    outValues: MySqlValue[] = []) {
    this.results = results.slice();
    this.outResultIndex = outResultIndex;
    this.outValues = [];
    for (const value of outValues) {
      this.outValues.push(value instanceof Uint8Array ? value.slice() : value);
    }
  }
}
