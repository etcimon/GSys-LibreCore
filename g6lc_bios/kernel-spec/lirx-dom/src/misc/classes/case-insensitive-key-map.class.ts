export type InferCaseInsensitiveKeyMapGetReturn<GKey extends string, GCaseInsensitiveKey extends string> =
  Extract<Lowercase<GCaseInsensitiveKey>, Lowercase<GKey>>;

export class CaseInsensitiveKeyMap<GKey extends string> {
  readonly #map: ReadonlyMap<Lowercase<GKey>, GKey>;

  constructor(
    input: Iterable<GKey>,
  ) {

    this.#map = new Map<Lowercase<GKey>, GKey>(
      Array.from(input, (key: GKey): [Lowercase<GKey>, GKey] => {
        return [
          key.toLowerCase() as Lowercase<GKey>,
          key,
        ];
      }),
    );
  }

  get<GCaseInsensitiveKey extends string>(
    caseInsensitiveKey: GCaseInsensitiveKey,
  ): InferCaseInsensitiveKeyMapGetReturn<GKey, GCaseInsensitiveKey> {
    const key: string | undefined = this.#map.get(caseInsensitiveKey.toLowerCase() as Lowercase<GKey>);
    if (key === void 0) {
      throw new Error(`Unable to find key: "${caseInsensitiveKey}"`);
    } else {
      return key as InferCaseInsensitiveKeyMapGetReturn<GKey, GCaseInsensitiveKey>;
    }
  }
}

export type IGenericCaseInsensitiveKeyMap = CaseInsensitiveKeyMap<string>;

// const a = new CaseInsensitiveKeyMap<'a' | 'B'>(['a', 'B']);
//
// const a = a.get('A');
// const a = a.get('B');
// const c = a.get('c');
