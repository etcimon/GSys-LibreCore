export interface IStyleProperty {
  value: string;
  priority: string;
}

export type ISetStyleProperty =
  Pick<IStyleProperty, 'value'>
  & Partial<Pick<IStyleProperty, 'priority'>>
  ;

export type ISetStylePropertyOrNull =
  | ISetStyleProperty
  | null
  ;

export type ISetStylePropertyOrStringOrNull =
  | ISetStylePropertyOrNull
  | string
  ;

export interface IGetStylePropertyOptions {
  computed?: boolean;
}
