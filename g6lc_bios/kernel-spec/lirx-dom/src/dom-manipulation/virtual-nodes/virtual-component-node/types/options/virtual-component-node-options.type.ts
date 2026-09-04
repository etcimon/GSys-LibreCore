import { IVirtualComponentNodeSlotsMap } from '../slots/virtual-component-node-slots-map.type';

export interface IVirtualComponentNodeOptions<GData extends object> {
  name: string;
  extends?: string;
  namespaceURI?: string,
  slots: IVirtualComponentNodeSlotsMap;
  data: GData;
}

// export type IVirtualComponentNodeOptions<GData extends object> = {
//     name: string;
//     extends?: string;
//     namespaceURI?: string,
//     slots?: IVirtualComponentNodeSlotsMap;
//   }
//   & InferVirtualComponentNodeOptionsData<GData>
//   ;
//
// export type InferVirtualComponentNodeOptionsData<GData extends object> =
//   object extends GData
//     ? {
//       data?: GData | undefined;
//     }
//     : {
//       data: GData;
//     }
//   ;
