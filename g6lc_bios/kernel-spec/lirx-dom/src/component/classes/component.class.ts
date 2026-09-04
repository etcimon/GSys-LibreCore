import {
  IVirtualComponentNodeSlotsMap,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { VirtualComponentNode } from '../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';
import { IComponentTemplate } from '../template/component-template.type';
import { IComponentStyle } from '../style/component-style.type';
import {
  IVirtualComponentNodeOptions,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/options/virtual-component-node-options.type';
import {
  applyTemplateForVirtualDOMNode,
} from '../../dom-manipulation/templates/virtual-dom-node-template/apply-template-for-virtual-dom-node';
import { AbstractComponent } from './abstract-component.class';
import { IComponentVirtualComponentNode } from './types/component-virtual-component-node.type';
import { IComponentInitComponentDataFunction } from './types/init-component-data/component-init-component-data-function.type';
import { IComponentInitTemplateDataFunction } from './types/init-template-data/component-init-template-data-function.type';
import { normalizeComponentInitComponentDataFunction } from './types/init-component-data/normalize-component-init-component-data-function';
import { normalizeComponentInitTemplateDataFunction } from './types/init-template-data/normalize-component-init-template-data-function';
import { IComponentOptions, IComponentMode } from './types/options/component-options.type';
import { DEFAULT_SLOTS } from './types/slots/default-slots.constant';
import { VirtualDOMNode } from '../../dom-manipulation/virtual-nodes/virtual-dom-node/virtual-dom-node.class';

/* CLASS */

/**
 * This class is used to define a Component:
 * a name, a template, some style, its inputs and outputs, and an "init" function.
 */
export class Component<GElement extends Element, GData extends object, GTemplateData extends object> extends AbstractComponent<GElement, GData> {

  // static html<GElement extends HTMLElement, GData extends object, GTemplateData extends object>(
  //   options?: IHTMLComponentOptions<GElement, GData, GTemplateData>,
  // ): Component<GElement, GData, GTemplateData> {
  //   return new (this)<GElement, GData, GTemplateData>({
  //     ...options,
  //     namespaceURI: HTML_NAMESPACE_URI_CONSTANT,
  //   } as IComponentOptions<GElement, GData, GTemplateData>);
  // }
  //
  // static svg<GElement extends SVGElement, GData extends object, GTemplateData extends object>(
  //   options?: ISVGComponentOptions<GElement, GData, GTemplateData>,
  // ): Component<GElement, GData, GTemplateData> {
  //   return new (this)<GElement, GData, GTemplateData>({
  //     ...options,
  //     namespaceURI: SVG_NAMESPACE_URI_CONSTANT,
  //   } as IComponentOptions<GElement, GData, GTemplateData>);
  // }
  //
  // static mathML<GElement extends MathMLElement, GData extends object, GTemplateData extends object>(
  //   options?: IMathMLComponentOptions<GElement, GData, GTemplateData>,
  // ): Component<GElement, GData, GTemplateData> {
  //   return new (this)<GElement, GData, GTemplateData>({
  //     ...options,
  //     namespaceURI: MATH_ML_NAMESPACE_URI_CONSTANT,
  //   } as IComponentOptions<GElement, GData, GTemplateData>);
  // }

  readonly #template: IComponentTemplate<GTemplateData> | undefined;
  readonly #styles: readonly IComponentStyle[];
  readonly #mode: IComponentMode;
  readonly #initComponentData: IComponentInitComponentDataFunction<GData>;
  readonly #initTemplateData: IComponentInitTemplateDataFunction<GElement, GData, GTemplateData>;
  readonly #nodeOptions: Omit<IVirtualComponentNodeOptions<GData>, 'slots' | 'data'>;

  constructor(
    {
      name,
      template,
      styles = [],
      mode = 'default',
      componentData,
      templateData,
      ...options
    }: IComponentOptions<GElement, GData, GTemplateData>,
  ) {
    super(name);

    this.#template = template;
    this.#styles = styles;
    this.#mode = mode;
    this.#initComponentData = normalizeComponentInitComponentDataFunction<GData>(componentData);
    this.#initTemplateData = normalizeComponentInitTemplateDataFunction<GElement, GData, GTemplateData>(templateData);
    this.#nodeOptions = {
      ...options,
      name,
    } as any;
  }

  override create(
    slots: IVirtualComponentNodeSlotsMap = DEFAULT_SLOTS,
  ): IComponentVirtualComponentNode<GElement, GData> {
    const node = this.#createNode(slots);

    this.#injectTemplate(
      (this.#mode === 'shadow')
        ? node.attachShadow()
        : node,
      this.#initTemplateData(node),
      slots,
    );

    this.#injectStyles(node);

    return node;
  }

  #createNode(
    slots: IVirtualComponentNodeSlotsMap,
  ): VirtualComponentNode<GElement, Readonly<GData>> {
    return new VirtualComponentNode<GElement, Readonly<GData>>({
      ...this.#nodeOptions,
      name: this.name,
      slots,
      data: this.#initComponentData() as GData,
    });
  }

  #injectTemplate(
    node: VirtualDOMNode,
    templateData: GTemplateData,
    slots: IVirtualComponentNodeSlotsMap,
  ): void {
    if (this.#template !== void 0) {
      applyTemplateForVirtualDOMNode(
        node,
        this.#template,
        [templateData, slots],
      );
    }
  }

  #injectStyles(
    node: VirtualComponentNode<GElement, Readonly<GData>>,
  ): void {
    for (let i: number = 0, l: number = this.#styles.length; i < l; i++) {
      this.#styles[i](node);
    }
  }
}

/* FUNCTIONS */

// // const h: ({a: string} extends object ? true : false);
// const a = new Component({
//   name: 'abc',
//   data: () => {
//     return {
//       a: '',
//     };
//   },
//   init: (node) => {
//     return {
//       b: 8,
//     };
//   },
// });
//
// const z = new Component<HTMLElement, { a: 'o' }, { b: number }>({
//   name: 'abc',
//   data: () => {
//     return {
//       a: 'o',
//     };
//   },
//   init: (node) => {
//     return {
//       b: 9,
//     };
//   },
// });
//
// const b = a.create();
// b.data.a;
