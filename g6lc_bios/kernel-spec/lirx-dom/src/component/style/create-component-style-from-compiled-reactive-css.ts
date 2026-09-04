import { IGenericVirtualElementNode } from '../../dom-manipulation/virtual-nodes/virtual-element-node/generic-virtual-element-node.type';
import { IComponentStyle } from './component-style.type';
import { ICompiledReactiveCSS } from './compile-style-as-compiled-reactive-css';

export function createComponentStyleFromCompiledReactiveCSS(
  {
    css,
    id,
  }: ICompiledReactiveCSS,
): IComponentStyle {
  const styleElement = document.createElement('style');
  styleElement.setAttribute('host', id);
  styleElement.textContent = css;

  let count: number = 0;

  const connect = (): void => {
    count++;
    if (count === 1) {
      document.head.appendChild(styleElement);
    }
  };

  const disconnect = (): void => {
    count--;
    if (count === 0) {
      document.head.removeChild(styleElement);
    }
  };

  return (
    node: IGenericVirtualElementNode,
  ): void => {
    node.setAttribute(id, '');

    let fistConnected: boolean = true;
    node.isConnected$((connected: boolean): void => {
      if (connected) {
        connect();
      } else if (!fistConnected) {
        disconnect();
      }
      fistConnected = false;
    });
  };
}
