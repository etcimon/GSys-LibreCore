export interface IHavingId<GId> {
  id: GId;
}

export type IHavingStringId = IHavingId<string>;
export type IHavingNumberId = IHavingId<number>;

export function trackById<GId>(
  item: IHavingId<GId>,
): GId {
  return item.id;
}
