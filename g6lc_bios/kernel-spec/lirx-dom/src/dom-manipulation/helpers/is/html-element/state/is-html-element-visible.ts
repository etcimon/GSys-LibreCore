export function isHTMLElementVisible(
  element: HTMLElement,
): boolean {
  return (
      (element.offsetWidth > 0)
      || (element.offsetHeight > 0)
      || (element.getClientRects().length > 0)
    )
    && (getComputedStyle(element).visibility === 'visible');
}
