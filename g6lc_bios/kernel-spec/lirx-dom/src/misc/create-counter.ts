export interface ICounter {
  (): number;
}

export function createCounter(
  count: number = 0,
): ICounter {
  return (): number => {
    return count++;
  };
}
