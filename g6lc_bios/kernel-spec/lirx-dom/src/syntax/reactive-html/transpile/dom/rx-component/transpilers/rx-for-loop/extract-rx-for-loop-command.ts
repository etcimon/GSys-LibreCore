import { IReactiveValue, extractReactiveValueFromString } from '../../../../misc/extract-reactive-value-from-string';

const LET_OF_PATTERN: string = 'let\\s+(\\S.*)\\s+of\\s+(\\S.*)';
const VARIABLE_AS_PATTERN: string = '(\\S.*)\\s+as\\s+(\\S.*)';
const OPTION_PATTERN: string = '(\\S.*)\\s*\\:\\s*(.*)';
const LET_OF_REGEXP: RegExp = new RegExp(`^${LET_OF_PATTERN}$`);
const VARIABLE_AS_REGEXP: RegExp = new RegExp(`^${VARIABLE_AS_PATTERN}$`);
const OPTION_REGEXP: RegExp = new RegExp(`^${OPTION_PATTERN}$`);

export interface IRXForLoopCommand {
  readonly items: IReactiveValue;
  readonly trackBy: string | undefined;
  // template variables
  readonly item: string;
  readonly index: string | undefined;
}

export function generateForCommandInvalidSyntaxError(
  expression: string,
  message: string,
): Error {
  return new Error(`Invalid syntax in the 'for' command '${expression}': ${message}`);
}

export function extractRXForLoopCommand(
  input: string,
): IRXForLoopCommand {
  let items: string;
  let trackBy: string | undefined;
  let item: string;
  let index: string | undefined;

  const expressions: string[] = input.split(';').map(_ => _.trim()).filter(_ => (_ !== ''));

  const length: number = expressions.length;
  if (length === 0) {
    throw generateForCommandInvalidSyntaxError(input, 'missing iterable');
  } else {
    const match: RegExpExecArray | null = LET_OF_REGEXP.exec(expressions[0]);
    if (match === null) {
      throw generateForCommandInvalidSyntaxError(input, `invalid 'let ... of ...' syntax`);
    } else {
      item = match[1];
      items = match[2];
    }
  }

  for (let i = 1; i < length; i++) {
    const expression: string = expressions[i];
    let match: RegExpExecArray | null;
    if ((match = VARIABLE_AS_REGEXP.exec(expression)) !== null) {
      const variableName: string = match[1];
      const variableMappedName: string = match[2];
      switch (variableName) {
        case 'index$':
          index = variableMappedName;
          break;
        default:
          throw generateForCommandInvalidSyntaxError(
            expression,
            `invalid local variable '${variableName}'`,
          );
      }
    } else if ((match = OPTION_REGEXP.exec(expression)) !== null) {
      const name: string = match[1];
      const value: string = match[2];
      switch (name) {
        case 'trackBy':
          trackBy = value;
          break;
        default:
          throw generateForCommandInvalidSyntaxError(
            expression,
            `invalid option '${name}'`,
          );
      }
    } else {
      throw generateForCommandInvalidSyntaxError(input, `unknown expression '${expression}'`);
    }
  }

  return {
    items: extractReactiveValueFromString(items),
    trackBy,
    item,
    index,
  };
}
