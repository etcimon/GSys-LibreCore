export type InferCaseInsensitiveObjectKey<GObject extends object, GKey extends string> = ({
  [Key in Extract<keyof GObject, string>]: Lowercase<GKey> extends Lowercase<Key>
    ? Key
    : never;
})[Extract<keyof GObject, string>];

