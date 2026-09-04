export function isCSSSupportsRule(
  rule: CSSRule,
): rule is CSSSupportsRule {
  return rule.constructor.name === 'CSSSupportsRule';
}
