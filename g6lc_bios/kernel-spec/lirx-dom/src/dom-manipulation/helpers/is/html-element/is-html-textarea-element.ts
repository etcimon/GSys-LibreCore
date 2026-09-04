export function isHTMLTextareaElement(
  input: Node,
): input is HTMLTextAreaElement {
  return (input instanceof HTMLTextAreaElement);
}
