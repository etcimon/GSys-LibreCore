export type InferElementKeys<GElementNode extends Element> = Extract<keyof GElementNode, string>;
