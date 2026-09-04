export function isCSSStyleRule(
  rule: CSSRule,
): rule is CSSStyleRule {
  return rule.constructor.name === 'CSSStyleRule';
}
