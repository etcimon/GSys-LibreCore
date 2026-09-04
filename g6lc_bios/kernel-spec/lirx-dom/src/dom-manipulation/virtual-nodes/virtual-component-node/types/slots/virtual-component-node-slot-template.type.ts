import { IVirtualDOMNodeTemplate } from '../../../../templates/virtual-dom-node-template/virtual-dom-node-template.type';

export type IVirtualComponentNodeSlotTemplate<GTemplateArgument extends object> = IVirtualDOMNodeTemplate<[GTemplateArgument]>;

// export type IVirtualComponentNodeSlotTemplate = IVirtualDOMNodeTemplate<[]>; // IGenericVirtualReactiveDOMNodeTemplate
