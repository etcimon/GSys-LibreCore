import { IComponentTemplate } from '../../../template/component-template.type';
import { IComponentStyle } from '../../../style/component-style.type';
import {
  IVirtualComponentNodeOptions,
} from '../../../../dom-manipulation/virtual-nodes/virtual-component-node/types/options/virtual-component-node-options.type';
import { InferComponentOptionsInitComponentDataFunction } from '../init-component-data/component-init-component-data-function.type';
import { InferComponentOptionsInitTemplateDataFunction } from '../init-template-data/component-init-template-data-function.type';

export type IComponentMode =
  | 'default'
  | 'shadow'
  ;

export type IComponentOptions<GElement extends Element, GData extends object, GTemplateData extends object> = {
    template?: IComponentTemplate<GTemplateData> | undefined;
    styles?: (readonly IComponentStyle[]) | undefined;
    mode?: IComponentMode | undefined;
  }
  & Omit<IVirtualComponentNodeOptions<GData>, 'slots' | 'data'>
  & InferComponentOptionsInitComponentDataFunction<GData>
  & InferComponentOptionsInitTemplateDataFunction<GElement, GData, GTemplateData>
  ;

// export type IHTMLComponentOptions<GElement extends HTMLElement, GData extends object, GTemplateData extends object> =
//   {
//     template?: IComponentTemplate<GTemplateData> | undefined;
//     styles?: (readonly IComponentStyle[]) | undefined;
//     mode?: IComponentMode | undefined;
//   }
//   & Omit<IVirtualComponentNodeOptions<GData>, 'slots' | 'data' | 'namespaceURI'>
//   & InferComponentOptionsInitComponentDataFunction<GData>
//   & InferComponentOptionsInitTemplateDataFunction<GElement, GData, GTemplateData>
//   ;
//
// export type ISVGComponentOptions<GElement extends SVGElement, GData extends object, GTemplateData extends object> =
//   {
//     template?: IComponentTemplate<GTemplateData> | undefined;
//     styles?: (readonly IComponentStyle[]) | undefined;
//     mode?: IComponentMode | undefined;
//   }
//   & Omit<IVirtualComponentNodeOptions<GData>, 'slots' | 'data' | 'namespaceURI'>
//   & InferComponentOptionsInitComponentDataFunction<GData>
//   & InferComponentOptionsInitTemplateDataFunction<GElement, GData, GTemplateData>
//   ;
//
// export type IMathMLComponentOptions<GElement extends MathMLElement, GData extends object, GTemplateData extends object> =
//   {
//     template?: IComponentTemplate<GTemplateData> | undefined;
//     styles?: (readonly IComponentStyle[]) | undefined;
//     mode?: IComponentMode | undefined;
//   }
//   & Omit<IVirtualComponentNodeOptions<GData>, 'slots' | 'data' | 'namespaceURI'>
//   & InferComponentOptionsInitComponentDataFunction<GData>
//   & InferComponentOptionsInitTemplateDataFunction<GElement, GData, GTemplateData>
//   ;

// export type IHTMLComponentOptions<GElement extends HTMLElement, GData extends object, GTemplateData extends object> =
//   Omit<IComponentOptions<GElement, GData, GTemplateData>, 'namespaceURI'>;

// export type ISVGComponentOptions<GElement extends SVGElement, GData extends object, GTemplateData extends object> =
//   Omit<IComponentOptions<GElement, GData, GTemplateData>, 'namespaceURI'>;
//
// export type IMathMLComponentOptions<GElement extends MathMLElement, GData extends object, GTemplateData extends object> =
//   Omit<IComponentOptions<GElement, GData, GTemplateData>, 'namespaceURI'>;
//
