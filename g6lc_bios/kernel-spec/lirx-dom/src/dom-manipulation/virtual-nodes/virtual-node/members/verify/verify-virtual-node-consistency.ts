import { VirtualNode } from '../../virtual-node.class';

function throwVerifyVirtualNodeConsistencyError(
  node: VirtualNode,
  message: string,
): void {
  console.log(node);
  throw new Error(message);
}

export function verifyVirtualNodeConsistency(
  node: VirtualNode,
): void {
  if (node.parentNode === null) {
    if (node.previousNode !== null) {
      throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode === null) && (node.previousNode !== null)`);
    }
    if (node.nextNode !== null) {
      throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode === null) && (node.nextNode !== null)`);
    }
  } else {
    if (node.parentNode.firstChild === null) {
      throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode !== null) && (node.parentNode.firstChild === null)`);
    }
    if (node.parentNode.lastChild === null) {
      throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode !== null) && (node.parentNode.lastChild === null)`);
    }

    if (node.previousNode === null) {
      if (node.parentNode.firstChild !== node) {
        throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode !== null) && (node.previousNode === null) && (node.parentNode.firstChild !== node)`);
      }
    } else {
      if (node.previousNode.nextNode !== node) {
        throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode !== null) && (node.previousNode !== null) && (node.previousNode.nextNode !== node)`);
      }
    }

    if (node.nextNode === null) {
      if (node.parentNode.lastChild !== node) {
        throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode !== null) && (node.nextNode === null) && (node.parentNode.lastChild !== node)`);
      }
    } else {
      if (node.nextNode.previousNode !== node) {
        throwVerifyVirtualNodeConsistencyError(node, `(node.parentNode !== null) && (node.nextNode !== null) && (node.nextNode.previousNode !== node)`);
      }
    }
  }

  for (const child of node.getChildren()) {
    verifyVirtualNodeConsistency(child);
  }
}
