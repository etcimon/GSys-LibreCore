export function extractParenthesisContent(
  input: string,
  position: number = 0,
): number {
  let count: number = 1;
  let i: number = position + 1;
  let j: number = 1000;

  while (count > 0 && (j-- > 0)) {
    const a: number = input.indexOf(')', i);
    const b: number = input.indexOf('(', i);

    if (a === -1) {
      throw new Error(`Missing closing parenthesis`);
    }

    if ((a < b) || (b === -1)) {
      count--;
      i = a + 1;
    } else {
      count++;
      i = b + 1;
    }
  }

  if (j <= 0) {
    throw new Error(`Too much parenthesis nesting`);
  }

  return i;
}

