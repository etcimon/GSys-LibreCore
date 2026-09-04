import { NULL_TEMPLATE } from './null-template.constant';

export function generateTemplateVariableName(
  templateName: string,
): string {
  return `template_${templateName}`;
}

/**
 * @deprecated
 */
export function generateOptionalTemplateVariableName(
  templateName: string | undefined,
): string {
  return (templateName === void 0)
    ? NULL_TEMPLATE
    : generateTemplateVariableName(templateName);
}

