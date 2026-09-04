export function sortFocusableHTMLElements(
  elements: HTMLElement[],
  reverse: boolean = false,
): HTMLElement[] {
  const endIndex: number = elements.length - 1;

  const tabIndexes: WeakMap<HTMLElement, [number, number]> = new WeakMap(
    elements.map((element: HTMLElement, index: number): [HTMLElement, [number, number]] => {
      return [
        element,
        [element.tabIndex, reverse ? (endIndex - index) : index],
      ];
    }),
  );

  return elements
    .sort((a: HTMLElement, b: HTMLElement): number => {
      const [tabIndexA, positionA] = tabIndexes.get(a)!;
      const [tabIndexB, positionB] = tabIndexes.get(b)!;

      if (tabIndexA === tabIndexB) {
        return positionA - positionB;
      } else {
        if (tabIndexA === -1) {
          return 1;
        } else if (tabIndexB === -1) {
          return -1;
        } else if (tabIndexA === 0) {
          return 1;
        } else if (tabIndexB === 0) {
          return -1;
        } else {
          return tabIndexA - tabIndexB;
        }
      }
    });
}
