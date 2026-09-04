export function isCSSMediaRule(
  rule: CSSRule,
): rule is CSSMediaRule {
  return rule.constructor.name === 'CSSMediaRule';
}
