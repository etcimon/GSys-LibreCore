export function isCSSContainerRule(
  rule: CSSRule,
): rule is CSSContainerRule {
  return rule.constructor.name === 'CSSContainerRule';
}
