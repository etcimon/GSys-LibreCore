import { IGenericVirtualElementNode } from '../../generic-virtual-element-node.type';

export function virtualElementNodeAppendClassName(
  node: IGenericVirtualElementNode,
  classNames: string | readonly string[],
): void {
  const className: string = Array.isArray(classNames)
    ? classNames.join(' ')
    : classNames as string;

  node.elementNode.className = (node.elementNode.className === '')
    ? className
    : `${node.elementNode.className} ${className}`;

  // if (typeof classNames === 'string') {
  //   classNames = classNames.split(/\s+/)
  //     .map(_ => _.trim())
  //     .filter(_ => (_ !== ''));
  // }
  //
  // for (let i = 0, l = classNames.length; i < l; i++) {
  //   node.setClass(classNames[i], true);
  // }
}
