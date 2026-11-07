import ts from 'typescript';

const MAX_STATIC_STRINGS = 64;
export const STATIC_STRING_INCOMPLETE = Symbol('static-string-incomplete');
export const DESCRIPTOR_MEMBERS = new Set([
  'getOwnPropertyDescriptor',
  'getOwnPropertyDescriptors'
]);

function scopeKind(node) {
  if (ts.isModuleBlock(node)) return 'module';
  if (ts.isBlock(node) || ts.isCaseBlock(node) || ts.isCatchClause(node) ||
    ts.isForStatement(node) || ts.isForInStatement(node) ||
    ts.isForOfStatement(node)) {
    return 'block';
  }
  return null;
}

function bindingIdentifiers(name) {
  if (ts.isIdentifier(name)) return [name];
  const identifiers = [];
  for (const element of name.elements) {
    if (ts.isOmittedExpression(element)) continue;
    identifiers.push(...bindingIdentifiers(element.name));
  }
  return identifiers;
}

function addValues(target, values, preservedStrings) {
  for (const value of values) {
    if (value === STATIC_STRING_INCOMPLETE) {
      target.add(value);
      continue;
    }
    if (target.has(value)) continue;
    const stringCount = target.size -
      (target.has(STATIC_STRING_INCOMPLETE) ? 1 : 0);
    if (stringCount >= MAX_STATIC_STRINGS &&
      !preservedStrings.has(value)) {
      target.add(STATIC_STRING_INCOMPLETE);
      continue;
    }
    target.add(value);
  }
}

function combineValues(left, right, preservedStrings) {
  const combined = new Set();
  if (left.has(STATIC_STRING_INCOMPLETE) ||
    right.has(STATIC_STRING_INCOMPLETE)) {
    combined.add(STATIC_STRING_INCOMPLETE);
  }
  for (const prefix of left) {
    if (prefix === STATIC_STRING_INCOMPLETE) continue;
    for (const suffix of right) {
      if (suffix === STATIC_STRING_INCOMPLETE) continue;
      addValues(
        combined,
        new Set([`${prefix}${suffix}`]),
        preservedStrings
      );
    }
  }
  return combined;
}

function createIdentifierBindingResolver(sourceFile) {
  const nodeScopes = new WeakMap();
  const rootScope = {
    parent: null,
    bindings: new Map(),
    kind: 'source'
  };

  function declare(scope, name) {
    let binding = scope.bindings.get(name);
    if (binding === undefined) {
      binding = {};
      scope.bindings.set(name, binding);
    }
    return binding;
  }

  function visit(node, parentScope) {
    if (node !== sourceFile && ts.isFunctionLike(node)) {
      if (ts.isFunctionDeclaration(node) && node.name !== undefined) {
        declare(parentScope, node.name.text);
      }
      const parameterScope = {
        parent: parentScope,
        bindings: new Map(),
        kind: 'parameter'
      };
      const functionScope = {
        parent: parameterScope,
        bindings: new Map(),
        kind: 'function'
      };
      nodeScopes.set(node, functionScope);
      if (ts.isFunctionExpression(node) && node.name !== undefined) {
        declare(parameterScope, node.name.text);
        declare(functionScope, node.name.text);
      }
      const parameters = new Set(node.parameters);
      ts.forEachChild(node, (child) => visit(
        child,
        parameters.has(child) ? parameterScope : functionScope
      ));
      return;
    }
    if (node !== sourceFile &&
      (ts.isClassDeclaration(node) ||
        ts.isClassExpression(node))) {
      if (ts.isClassDeclaration(node) && node.name !== undefined) {
        declare(parentScope, node.name.text);
      }
      const classScope = {
        parent: parentScope,
        bindings: new Map(),
        kind: 'class'
      };
      nodeScopes.set(node, classScope);
      if (ts.isClassExpression(node) && node.name !== undefined) {
        declare(classScope, node.name.text);
      }
      ts.forEachChild(node, (child) => visit(child, classScope));
      return;
    }
    if (node !== sourceFile && ts.isModuleDeclaration(node) &&
      ts.isIdentifier(node.name)) {
      declare(parentScope, node.name.text);
    }
    const kind = scopeKind(node);
    const scope = node === sourceFile
      ? rootScope
      : kind !== null
        ? { parent: parentScope, bindings: new Map(), kind }
        : parentScope;
    nodeScopes.set(node, scope);

    if (ts.isVariableDeclaration(node)) {
      const blockScoped = !ts.isVariableDeclarationList(node.parent) ||
        (node.parent.flags & ts.NodeFlags.BlockScoped) !== 0;
      let declarationScope = scope;
      while (!blockScoped && declarationScope.kind === 'block') {
        declarationScope = declarationScope.parent;
      }
      for (const identifier of bindingIdentifiers(node.name)) {
        declare(declarationScope, identifier.text);
      }
    } else if (ts.isParameter(node)) {
      for (const identifier of bindingIdentifiers(node.name)) {
        declare(scope, identifier.text);
      }
    } else if (ts.isImportClause(node) && node.name !== undefined) {
      declare(scope, node.name.text);
    } else if (ts.isNamespaceImport(node)) {
      declare(scope, node.name.text);
    } else if (ts.isImportSpecifier(node)) {
      declare(scope, node.name.text);
    }

    ts.forEachChild(node, (child) => visit(child, scope));
  }

  function resolve(identifier) {
    let scope = nodeScopes.get(identifier);
    while (scope !== undefined && scope !== null) {
      const binding = scope.bindings.get(identifier.text);
      if (binding !== undefined) return binding;
      scope = scope.parent;
    }
    return null;
  }

  visit(sourceFile, rootScope);
  return resolve;
}

export function createDescriptorCallResolver(
  sourceFile,
  unwrap,
  staticStrings
) {
  const resolveBinding = createIdentifierBindingResolver(sourceFile);
  const globalObject = {};
  const objectAliases = new Set([globalObject]);
  const prototypeFunctionAliases = new Set();
  const prototypeAliases = new Set();
  const descriptorAliases = new Map();

  function identifierBinding(identifier) {
    const binding = resolveBinding(identifier);
    if (binding !== null) return binding;
    return identifier.text === 'Object' ? globalObject : null;
  }

  function addDescriptorAliases(name, values) {
    let aliases = descriptorAliases.get(name);
    if (aliases === undefined) {
      aliases = new Set();
      descriptorAliases.set(name, aliases);
    }
    for (const value of values) aliases.add(value);
  }

  function assignedIdentifier(node) {
    const expression = unwrap(node);
    if (ts.isIdentifier(expression)) return expression;
    if (ts.isBinaryExpression(expression) &&
      expression.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      expression.operatorToken.kind <= ts.SyntaxKind.LastAssignment &&
      ts.isIdentifier(unwrap(expression.left))) {
      return unwrap(expression.left);
    }
    return null;
  }

  function recordAliasFacts(target, sourceNode) {
    if (target === null) return;
    const source = unwrap(sourceNode);
    const assigned = assignedIdentifier(source);
    const assignedBinding = assigned === null
      ? null
      : identifierBinding(assigned);
    if (assignedBinding !== null && objectAliases.has(assignedBinding)) {
      objectAliases.add(target);
    }
    if (prototypeExpression(source)) {
      prototypeAliases.add(target);
    } else if (assignedBinding !== null &&
      prototypeAliases.has(assignedBinding)) {
      prototypeAliases.add(target);
    }
    if (prototypeFunctionExpression(source)) {
      prototypeFunctionAliases.add(target);
    } else if (assignedBinding !== null &&
      prototypeFunctionAliases.has(assignedBinding)) {
      prototypeFunctionAliases.add(target);
    }
    const descriptorMembers = trustedMembers(source, DESCRIPTOR_MEMBERS);
    if (descriptorMembers.size > 0) {
      addDescriptorAliases(target, descriptorMembers);
    } else if (assignedBinding !== null &&
      descriptorAliases.has(assignedBinding)) {
      addDescriptorAliases(
        target, descriptorAliases.get(assignedBinding));
    }
  }

  function collectPatternAliases(targetNode, sourceNode) {
    const target = unwrap(targetNode);
    const source = unwrap(sourceNode);
    if (ts.isIdentifier(target)) {
      recordAliasFacts(identifierBinding(target), source);
      return;
    }
    const bindingElements = ts.isArrayBindingPattern(target)
      ? target.elements
      : ts.isArrayLiteralExpression(target)
        ? target.elements
        : null;
    function flattenedArrayElements(array) {
      const elements = [];
      for (const element of array.elements) {
        if (!ts.isSpreadElement(element)) {
          elements.push(element);
          continue;
        }
        const spread = unwrap(element.expression);
        if (!ts.isArrayLiteralExpression(spread)) return null;
        const nested = flattenedArrayElements(spread);
        if (nested === null) return null;
        elements.push(...nested);
      }
      return elements;
    }
    const sourceElements = ts.isArrayLiteralExpression(source)
      ? flattenedArrayElements(source)
      : null;
    if (bindingElements === null || sourceElements === null) {
      const sourceBinding = ts.isIdentifier(source)
        ? identifierBinding(source)
        : null;
      const objectElements = ts.isObjectBindingPattern(target)
        ? target.elements
        : ts.isObjectLiteralExpression(target)
          ? target.properties
          : [];
      for (const element of objectElements) {
        let propertyNode;
        let targetNode;
        if (ts.isBindingElement(element)) {
          propertyNode = element.propertyName ?? element.name;
          targetNode = element.name;
        } else if (ts.isPropertyAssignment(element)) {
          propertyNode = element.name;
          targetNode = element.initializer;
        } else if (ts.isShorthandPropertyAssignment(element)) {
          propertyNode = element.name;
          targetNode = element.name;
        } else {
          continue;
        }
        const propertyNames = ts.isComputedPropertyName(propertyNode)
          ? staticStrings(propertyNode.expression)
          : ts.isIdentifier(propertyNode) ||
            ts.isStringLiteralLike(propertyNode)
            ? new Set([propertyNode.text])
            : new Set();
        if (ts.isObjectLiteralExpression(source)) {
          const sourceProperty = source.properties.find((property) => {
            if (!ts.isPropertyAssignment(property) &&
              !ts.isShorthandPropertyAssignment(property)) {
              return false;
            }
            const sourceName = ts.isComputedPropertyName(property.name)
              ? staticStrings(property.name.expression)
              : ts.isIdentifier(property.name) ||
                ts.isStringLiteralLike(property.name)
                ? new Set([property.name.text])
                : new Set();
            return [...sourceName].some((name) =>
              propertyNames.has(name));
          });
          if (sourceProperty !== undefined) {
            collectPatternAliases(
              targetNode,
              ts.isPropertyAssignment(sourceProperty)
                ? sourceProperty.initializer
                : sourceProperty.name
            );
          }
          continue;
        }
        if (!objectAliases.has(sourceBinding)) continue;
        const targetExpression = unwrap(targetNode);
        if (!ts.isIdentifier(targetExpression)) continue;
        const targetBinding = identifierBinding(targetExpression);
        if (propertyNames.has('getPrototypeOf')) {
          prototypeFunctionAliases.add(targetBinding);
        }
        const descriptorMembers = new Set(
          [...propertyNames].filter((name) =>
            DESCRIPTOR_MEMBERS.has(name)));
        if (descriptorMembers.size > 0) {
          addDescriptorAliases(targetBinding, descriptorMembers);
        }
      }
      return;
    }
    for (let index = 0; index < bindingElements.length; index += 1) {
      const element = bindingElements[index];
      if (ts.isOmittedExpression(element) ||
        ts.isSpreadElement(element) ||
        (ts.isBindingElement(element) &&
          element.dotDotDotToken !== undefined)) {
        continue;
      }
      const sourceElement = sourceElements[index];
      if (sourceElement === undefined) continue;
      collectPatternAliases(
        ts.isBindingElement(element) ? element.name : element,
        sourceElement
      );
    }
  }

  function memberNames(node) {
    const expression = unwrap(node);
    if (ts.isPropertyAccessExpression(expression)) {
      return new Set([expression.name.text]);
    }
    if (ts.isElementAccessExpression(expression) &&
      expression.argumentExpression !== undefined) {
      return staticStrings(expression.argumentExpression);
    }
    return new Set();
  }

  function trustedMembers(node, names) {
    const expression = unwrap(node);
    if (!ts.isPropertyAccessExpression(expression) &&
      !ts.isElementAccessExpression(expression)) {
      return new Set();
    }
    const receiver = unwrap(expression.expression);
    if (!ts.isIdentifier(receiver) ||
      !objectAliases.has(identifierBinding(receiver))) {
      return new Set();
    }
    return new Set([...memberNames(expression)].filter((name) =>
      names.has(name)));
  }

  function descriptorEscape(node) {
    let expression = node;
    while (expression.parent !== undefined &&
      ((ts.isParenthesizedExpression(expression.parent) ||
        ts.isAsExpression(expression.parent) ||
        ts.isTypeAssertionExpression(expression.parent) ||
        ts.isSatisfiesExpression(expression.parent) ||
        ts.isNonNullExpression(expression.parent)) &&
        expression.parent.expression === expression)) {
      expression = expression.parent;
    }
    const parent = expression.parent;
    if (parent === undefined) return false;
    if (ts.isVariableDeclaration(parent) &&
      parent.initializer === expression) {
      return !ts.isIdentifier(parent.name);
    }
    if (ts.isBinaryExpression(parent) &&
      parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      parent.right === expression) {
      return !ts.isIdentifier(unwrap(parent.left));
    }
    if ((ts.isPropertyAccessExpression(parent) ||
      ts.isElementAccessExpression(parent)) &&
      parent.expression === expression) {
      return false;
    }
    if (ts.isCallExpression(parent) &&
      parent.expression === expression) {
      return false;
    }
    return (ts.isPropertyAssignment(parent) &&
      parent.initializer === expression) ||
      (ts.isShorthandPropertyAssignment(parent) &&
        parent.name === expression) ||
      (ts.isArrayLiteralExpression(parent) &&
        parent.elements.includes(expression)) ||
      (ts.isReturnStatement(parent) &&
        parent.expression === expression) ||
      (ts.isArrowFunction(parent) &&
        parent.body === expression) ||
      (ts.isCallExpression(parent) &&
        parent.arguments.includes(expression)) ||
      (ts.isNewExpression(parent) &&
        parent.arguments?.includes(expression) === true) ||
      (ts.isConditionalExpression(parent) &&
        (parent.whenTrue === expression ||
          parent.whenFalse === expression));
  }

  function prototypeFunctionExpression(node) {
    const expression = unwrap(node);
    if (trustedMembers(
      expression, new Set(['getPrototypeOf'])).size > 0 ||
      (ts.isIdentifier(expression) &&
        prototypeFunctionAliases.has(identifierBinding(expression)))) {
      return true;
    }
    if (!ts.isCallExpression(expression)) return false;
    const callee = unwrap(expression.expression);
    const wrapper = [...memberNames(callee)].find((name) =>
      name === 'bind');
    return wrapper !== undefined &&
      (ts.isPropertyAccessExpression(callee) ||
        ts.isElementAccessExpression(callee)) &&
      prototypeFunctionExpression(callee.expression);
  }

  function prototypeExpression(node) {
    const expression = unwrap(node);
    if (!ts.isCallExpression(expression)) return false;
    let callee = unwrap(expression.expression);
    const wrapper = [...memberNames(callee)].find((name) =>
      name === 'apply' || name === 'call');
    if (wrapper !== undefined &&
      (ts.isPropertyAccessExpression(callee) ||
        ts.isElementAccessExpression(callee))) {
      callee = unwrap(callee.expression);
    }
    return prototypeFunctionExpression(callee);
  }

  function collectAliases(node) {
    if (ts.isParameter(node) && ts.isIdentifier(node.name) &&
      node.initializer !== undefined) {
      recordAliasFacts(
        identifierBinding(node.name),
        node.initializer
      );
    } else if (ts.isBindingElement(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer !== undefined) {
      recordAliasFacts(
        identifierBinding(node.name),
        node.initializer
      );
    } else if (ts.isVariableDeclaration(node) &&
      node.initializer !== undefined) {
      collectPatternAliases(node.name, node.initializer);
    } else if (ts.isBinaryExpression(node) &&
      node.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      node.operatorToken.kind <= ts.SyntaxKind.LastAssignment) {
      collectPatternAliases(node.left, node.right);
    }
    ts.forEachChild(node, collectAliases);
  }

  function aliasFactCount() {
    return objectAliases.size + prototypeFunctionAliases.size +
      prototypeAliases.size +
      [...descriptorAliases.values()].reduce(
        (count, aliases) => count + aliases.size, 0);
  }

  let priorAliasCount = -1;
  while (priorAliasCount !== aliasFactCount()) {
    priorAliasCount = aliasFactCount();
    collectAliases(sourceFile);
  }

  return (node) => {
    const directEscapedMembers = trustedMembers(node, DESCRIPTOR_MEMBERS);
    const escapedMembers = directEscapedMembers.size > 0
      ? directEscapedMembers
      : ts.isIdentifier(unwrap(node))
        ? descriptorAliases.get(
          identifierBinding(unwrap(node))) ?? new Set()
        : new Set();
    if (escapedMembers.size > 0 && descriptorEscape(node)) return true;
    if (!ts.isCallExpression(node)) return false;
    let callee = unwrap(node.expression);
    const wrapperNames = memberNames(callee);
    const invocationKinds = new Set([...wrapperNames].filter((name) =>
      ['apply', 'bind', 'call'].includes(name)));
    if (invocationKinds.size > 0 &&
      (ts.isPropertyAccessExpression(callee) ||
        ts.isElementAccessExpression(callee))) {
      callee = unwrap(callee.expression);
    } else {
      invocationKinds.add('direct');
    }

    const directMembers = trustedMembers(callee, DESCRIPTOR_MEMBERS);
    const descriptorMembers = directMembers.size === 0
      ? ts.isIdentifier(callee)
        ? descriptorAliases.get(identifierBinding(callee)) ?? new Set()
        : new Set()
      : directMembers;
    if (descriptorMembers.size === 0) return false;

    for (const invocationKind of invocationKinds) {
      let descriptorArguments = [...node.arguments];
      let unresolvedApplyArguments = false;
      if (invocationKind === 'apply') {
        const argumentArray = node.arguments[1] === undefined
          ? null
          : unwrap(node.arguments[1]);
        descriptorArguments = ts.isArrayLiteralExpression(argumentArray) &&
          !argumentArray.elements.some((element) =>
            ts.isSpreadElement(element))
          ? [...argumentArray.elements]
          : [];
        unresolvedApplyArguments = descriptorArguments.length === 0;
      } else if (invocationKind === 'call' ||
        invocationKind === 'bind') {
        descriptorArguments = descriptorArguments.slice(1);
      }
      if (unresolvedApplyArguments) return true;
      if (invocationKind === 'bind' &&
        descriptorArguments.length === 0) {
        return true;
      }

      const prototypeTarget = descriptorArguments[0];
      const prototypeMatches = prototypeTarget !== undefined &&
        (prototypeExpression(prototypeTarget) ||
          (ts.isIdentifier(unwrap(prototypeTarget)) &&
            prototypeAliases.has(
              identifierBinding(unwrap(prototypeTarget)))));
      if (!prototypeMatches) continue;
      if (descriptorMembers.has('getOwnPropertyDescriptors')) return true;
      if (invocationKind === 'bind' &&
        descriptorArguments.length < 2) {
        return true;
      }

      const keyNames = descriptorArguments[1] === undefined
        ? new Set()
        : staticStrings(descriptorArguments[1]);
      if (descriptorMembers.has('getOwnPropertyDescriptor') &&
        (keyNames.has('constructor') ||
          keyNames.has(STATIC_STRING_INCOMPLETE))) {
        return true;
      }
    }
    return false;
  };
}

export function createStaticStringResolver(
  sourceFile,
  unwrap = (node) => node,
  preservedStrings = new Set()
) {
  const preservedFragments = new Set();
  for (const value of preservedStrings) {
    for (let start = 0; start < value.length; start += 1) {
      for (let end = start + 1; end <= value.length; end += 1) {
        preservedFragments.add(value.slice(start, end));
      }
    }
  }
  const nodeScopes = new WeakMap();
  const declarationBindings = new WeakMap();
  const rootScope = {
    parent: null,
    bindings: new Map(),
    kind: 'source'
  };

  function declare(scope, name, declaration) {
    let binding = scope.bindings.get(name);
    if (binding === undefined && scope.kind === 'function' &&
      scope.parent?.kind === 'parameter') {
      binding = scope.parent.bindings.get(name);
    }
    if (binding === undefined) {
      binding = {
        appends: [],
        forceIncomplete: false,
        sources: [],
        uncertain: false
      };
      scope.bindings.set(name, binding);
    }
    declarationBindings.set(declaration, binding);
    return binding;
  }

  function visitScopes(node, parentScope) {
    if (node !== sourceFile && ts.isFunctionLike(node)) {
      const parameterScope = {
        parent: parentScope,
        bindings: new Map(),
        kind: 'parameter'
      };
      const functionScope = {
        parent: parameterScope,
        bindings: new Map(),
        kind: 'function'
      };
      nodeScopes.set(node, functionScope);
      const parameters = new Set(node.parameters);
      ts.forEachChild(node, (child) => visitScopes(
        child,
        parameters.has(child) ? parameterScope : functionScope
      ));
      return;
    }
    const kind = scopeKind(node);
    const scope = node === sourceFile
      ? rootScope
      : kind !== null
        ? { parent: parentScope, bindings: new Map(), kind }
        : parentScope;
    nodeScopes.set(node, scope);

    if (ts.isVariableDeclaration(node)) {
      const blockScoped = !ts.isVariableDeclarationList(node.parent) ||
        (node.parent.flags & ts.NodeFlags.BlockScoped) !== 0;
      let declarationScope = scope;
      while (!blockScoped && declarationScope.kind === 'block') {
        declarationScope = declarationScope.parent;
      }
      for (const identifier of bindingIdentifiers(node.name)) {
        declare(declarationScope, identifier.text, node);
      }
    } else if (ts.isParameter(node)) {
      for (const identifier of bindingIdentifiers(node.name)) {
        declare(scope, identifier.text, node);
      }
    } else if (ts.isImportClause(node) && node.name !== undefined) {
      declare(scope, node.name.text, node).forceIncomplete = true;
    } else if (ts.isNamespaceImport(node)) {
      declare(scope, node.name.text, node).forceIncomplete = true;
    } else if (ts.isImportSpecifier(node)) {
      declare(scope, node.name.text, node).forceIncomplete = true;
    }

    ts.forEachChild(node, (child) => visitScopes(child, scope));
  }

  function resolveBinding(identifier) {
    let scope = nodeScopes.get(identifier);
    while (scope !== undefined && scope !== null) {
      const binding = scope.bindings.get(identifier.text);
      if (binding !== undefined) return binding;
      scope = scope.parent;
    }
    return null;
  }

  visitScopes(sourceFile, rootScope);

  function referencesBinding(node, binding) {
    let found = false;
    function visit(current) {
      if (found) return;
      if (ts.isIdentifier(current) &&
        resolveBinding(current) === binding) {
        found = true;
        return;
      }
      ts.forEachChild(current, visit);
    }
    visit(node);
    return found;
  }

  function propertyName(node) {
    if (ts.isIdentifier(node) || ts.isStringLiteralLike(node) ||
      ts.isNumericLiteral(node)) {
      return node.text;
    }
    return null;
  }

  function objectValue(expression, name) {
    const object = unwrap(expression);
    if (!ts.isObjectLiteralExpression(object)) return null;
    for (let index = object.properties.length - 1; index >= 0; index -= 1) {
      const property = object.properties[index];
      if (ts.isSpreadAssignment(property)) return null;
      if (ts.isPropertyAssignment(property)) {
        const key = propertyName(property.name);
        if (key === null) return null;
        if (key === name) return property.initializer;
        continue;
      }
      if (ts.isShorthandPropertyAssignment(property)) {
        if (property.name.text === name) return property.name;
        continue;
      }
      const key = propertyName(property.name);
      if (key === null || key === name) return null;
    }
    return null;
  }

  function collectBindingSources(name, expression) {
    if (ts.isIdentifier(name)) {
      const binding = resolveBinding(name);
      if (binding !== null) binding.sources.push(expression);
      return;
    }
    const value = unwrap(expression);
    if (ts.isArrayBindingPattern(name) &&
      ts.isArrayLiteralExpression(value)) {
      for (let index = 0; index < name.elements.length; index += 1) {
        const element = name.elements[index];
        if (ts.isOmittedExpression(element)) continue;
        if (element.dotDotDotToken !== undefined) {
          for (const identifier of bindingIdentifiers(element.name)) {
            const binding = resolveBinding(identifier);
            if (binding !== null) binding.forceIncomplete = true;
          }
          continue;
        }
        if (value.elements.slice(0, index + 1).some((source) =>
          ts.isSpreadElement(source))) {
          for (const identifier of bindingIdentifiers(element.name)) {
            const binding = resolveBinding(identifier);
            if (binding !== null) binding.forceIncomplete = true;
          }
          continue;
        }
        const source = value.elements[index];
        if (source !== undefined && !ts.isSpreadElement(source)) {
          collectBindingSources(element.name, source);
        } else {
          for (const identifier of bindingIdentifiers(element.name)) {
            const binding = resolveBinding(identifier);
            if (binding !== null) binding.forceIncomplete = true;
          }
        }
        if (element.initializer !== undefined) {
          collectBindingSources(element.name, element.initializer);
        }
      }
      return;
    }
    if (ts.isObjectBindingPattern(name) &&
      ts.isObjectLiteralExpression(value)) {
      for (const element of name.elements) {
        const key = propertyName(element.propertyName ?? element.name);
        const source = key === null ? null : objectValue(value, key);
        if (source !== null) {
          collectBindingSources(element.name, source);
        } else {
          for (const identifier of bindingIdentifiers(element.name)) {
            const binding = resolveBinding(identifier);
            if (binding !== null) binding.forceIncomplete = true;
          }
        }
        if (element.initializer !== undefined) {
          collectBindingSources(element.name, element.initializer);
        }
      }
      return;
    }
    for (const identifier of bindingIdentifiers(name)) {
      const binding = resolveBinding(identifier);
      if (binding !== null) binding.forceIncomplete = true;
    }
  }

  function markBindingsIncomplete(node) {
    if (ts.isIdentifier(node)) {
      const binding = resolveBinding(node);
      if (binding !== null) binding.forceIncomplete = true;
      return;
    }
    ts.forEachChild(node, markBindingsIncomplete);
  }

  function collectAssignmentSources(targetNode, valueNode) {
    const target = unwrap(targetNode);
    const value = unwrap(valueNode);
    if (ts.isIdentifier(target)) {
      const binding = resolveBinding(target);
      if (binding !== null) binding.sources.push(valueNode);
      return;
    }
    if (ts.isArrayLiteralExpression(target) &&
      ts.isArrayLiteralExpression(value)) {
      for (let index = 0; index < target.elements.length; index += 1) {
        const element = target.elements[index];
        if (ts.isOmittedExpression(element)) continue;
        if (ts.isSpreadElement(element)) {
          markBindingsIncomplete(element.expression);
          continue;
        }
        if (value.elements.slice(0, index + 1).some((source) =>
          ts.isSpreadElement(source))) {
          markBindingsIncomplete(element);
          continue;
        }
        const source = value.elements[index];
        if (source !== undefined && !ts.isSpreadElement(source)) {
          collectAssignmentSources(element, source);
        } else {
          markBindingsIncomplete(element);
        }
      }
      return;
    }
    if (ts.isObjectLiteralExpression(target) &&
      ts.isObjectLiteralExpression(value)) {
      for (const property of target.properties) {
        if (ts.isShorthandPropertyAssignment(property)) {
          const source = objectValue(value, property.name.text);
          if (source !== null) {
            collectAssignmentSources(property.name, source);
          } else {
            markBindingsIncomplete(property.name);
          }
        } else if (ts.isPropertyAssignment(property)) {
          const key = propertyName(property.name);
          const source = key === null ? null : objectValue(value, key);
          if (source !== null) {
            collectAssignmentSources(property.initializer, source);
          } else {
            markBindingsIncomplete(property.initializer);
          }
        } else {
          markBindingsIncomplete(property);
        }
      }
      return;
    }
    markBindingsIncomplete(target);
  }

  function collectSources(node) {
    if (ts.isForOfStatement(node) || ts.isForInStatement(node)) {
      const initializer = node.initializer;
      const literalValues = ts.isForOfStatement(node) &&
        ts.isArrayLiteralExpression(unwrap(node.expression))
        ? unwrap(node.expression).elements
        : [];
      const hasSpread = literalValues.some((element) =>
        ts.isSpreadElement(element));
      const values = literalValues.length > 0
        ? literalValues.filter((element) =>
          !ts.isSpreadElement(element))
        : [];
      if (ts.isVariableDeclarationList(initializer)) {
        for (const declaration of initializer.declarations) {
          if (values.length > 0) {
            for (const value of values) {
              collectBindingSources(declaration.name, value);
            }
          } else {
            for (const identifier of bindingIdentifiers(declaration.name)) {
              const binding = resolveBinding(identifier);
              if (binding !== null) binding.forceIncomplete = true;
            }
          }
          if (hasSpread) {
            for (const identifier of bindingIdentifiers(declaration.name)) {
              const binding = resolveBinding(identifier);
              if (binding !== null) binding.forceIncomplete = true;
            }
          }
        }
      } else if (values.length > 0) {
        for (const value of values) {
          collectAssignmentSources(initializer, value);
        }
        if (hasSpread) markBindingsIncomplete(initializer);
      } else {
        markBindingsIncomplete(initializer);
      }
    } else if (ts.isVariableDeclaration(node) || ts.isParameter(node)) {
      if (ts.isParameter(node)) {
        for (const identifier of bindingIdentifiers(node.name)) {
          const binding = resolveBinding(identifier);
          if (binding !== null) binding.forceIncomplete = true;
        }
      }
      if (node.initializer !== undefined) {
        if (ts.isIdentifier(node.name)) {
          declarationBindings.get(node)?.sources.push(node.initializer);
        } else {
          collectBindingSources(node.name, node.initializer);
        }
      } else if (!ts.isIdentifier(node.name)) {
        for (const identifier of bindingIdentifiers(node.name)) {
          const binding = resolveBinding(identifier);
          if (binding !== null) binding.forceIncomplete = true;
        }
      } else if (!ts.isParameter(node)) {
        const declarationList = node.parent;
        const loop = ts.isVariableDeclarationList(declarationList)
          ? declarationList.parent
          : null;
        if (loop === null ||
          (!ts.isForOfStatement(loop) && !ts.isForInStatement(loop))) {
          declarationBindings.get(node).forceIncomplete = true;
        }
      }
    } else if (ts.isBinaryExpression(node) &&
      node.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      node.operatorToken.kind <= ts.SyntaxKind.LastAssignment) {
      const target = unwrap(node.left);
      if (ts.isIdentifier(target)) {
        const binding = resolveBinding(target);
        if (binding !== null) {
          if (node.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
            const right = unwrap(node.right);
            if (ts.isBinaryExpression(right) &&
              right.operatorToken.kind === ts.SyntaxKind.PlusToken &&
              ts.isIdentifier(unwrap(right.left)) &&
              resolveBinding(unwrap(right.left)) === binding) {
              binding.appends.push(right.right);
            } else if (referencesBinding(node.right, binding)) {
              binding.uncertain = true;
            } else {
              binding.sources.push(node.right);
            }
          } else if (node.operatorToken.kind ===
            ts.SyntaxKind.PlusEqualsToken) {
            binding.appends.push(node.right);
          } else if ([
            ts.SyntaxKind.AmpersandAmpersandEqualsToken,
            ts.SyntaxKind.BarBarEqualsToken,
            ts.SyntaxKind.QuestionQuestionEqualsToken
          ].includes(node.operatorToken.kind)) {
            binding.sources.push(node.right);
            binding.uncertain = true;
          } else {
            binding.uncertain = true;
          }
        }
      } else if (node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
        (ts.isArrayLiteralExpression(target) ||
          ts.isObjectLiteralExpression(target))) {
        collectAssignmentSources(target, node.right);
      } else if (ts.isElementAccessExpression(target) ||
        ts.isPropertyAccessExpression(target)) {
        const receiver = unwrap(target.expression);
        if (ts.isIdentifier(receiver)) {
          const binding = resolveBinding(receiver);
          if (binding !== null) binding.forceIncomplete = true;
        }
      }
    } else if ((ts.isPrefixUnaryExpression(node) ||
      ts.isPostfixUnaryExpression(node)) &&
      (node.operator === ts.SyntaxKind.PlusPlusToken ||
        node.operator === ts.SyntaxKind.MinusMinusToken)) {
      const target = unwrap(node.operand);
      if (ts.isIdentifier(target)) {
        const binding = resolveBinding(target);
        if (binding !== null) binding.uncertain = true;
      }
    }
    ts.forEachChild(node, collectSources);
  }

  collectSources(sourceFile);

  function values(node, seenBindings = new Set()) {
    const expression = unwrap(node);
    if (ts.isStringLiteralLike(expression)) {
      return new Set([expression.text]);
    }
    if (ts.isTemplateExpression(expression)) {
      let resolved = new Set([expression.head.text]);
      for (const span of expression.templateSpans) {
        resolved = combineValues(
          resolved,
          values(span.expression, seenBindings),
          preservedFragments
        );
        if (resolved.size === 0) return resolved;
        resolved = combineValues(
          resolved,
          new Set([span.literal.text]),
          preservedFragments
        );
      }
      return resolved;
    }
    if (ts.isBinaryExpression(expression)) {
      if (expression.operatorToken.kind === ts.SyntaxKind.PlusToken) {
        return combineValues(
          values(expression.left, seenBindings),
          values(expression.right, seenBindings),
          preservedFragments
        );
      }
      if ([
        ts.SyntaxKind.AmpersandAmpersandToken,
        ts.SyntaxKind.BarBarToken,
        ts.SyntaxKind.QuestionQuestionToken
      ].includes(expression.operatorToken.kind)) {
        const resolved = values(expression.left, seenBindings);
        addValues(
          resolved,
          values(expression.right, seenBindings),
          preservedFragments
        );
        return resolved;
      }
      if (expression.operatorToken.kind === ts.SyntaxKind.EqualsToken ||
        expression.operatorToken.kind === ts.SyntaxKind.CommaToken) {
        return values(expression.right, seenBindings);
      }
      if (expression.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
        expression.operatorToken.kind <= ts.SyntaxKind.LastAssignment) {
        return new Set([STATIC_STRING_INCOMPLETE]);
      }
    }
    if (ts.isConditionalExpression(expression)) {
      const resolved = values(expression.whenTrue, seenBindings);
      addValues(
        resolved,
        values(expression.whenFalse, seenBindings),
        preservedFragments
      );
      return resolved;
    }
    if (ts.isArrayLiteralExpression(expression)) {
      return new Set([STATIC_STRING_INCOMPLETE]);
    }
    if (ts.isObjectLiteralExpression(expression)) {
      return new Set([STATIC_STRING_INCOMPLETE]);
    }
    if (ts.isNumericLiteral(expression) ||
      expression.kind === ts.SyntaxKind.TrueKeyword ||
      expression.kind === ts.SyntaxKind.FalseKeyword ||
      expression.kind === ts.SyntaxKind.NullKeyword) {
      return new Set();
    }
    if (!ts.isIdentifier(expression)) {
      return new Set([STATIC_STRING_INCOMPLETE]);
    }

    const binding = resolveBinding(expression);
    if (binding === null || seenBindings.has(binding)) {
      return new Set([STATIC_STRING_INCOMPLETE]);
    }
    seenBindings.add(binding);
    const resolved = new Set();
    if (binding.forceIncomplete) resolved.add(STATIC_STRING_INCOMPLETE);
    for (const source of binding.sources) {
      addValues(
        resolved,
        values(source, seenBindings),
        preservedFragments
      );
    }
    if (binding.uncertain) resolved.add(STATIC_STRING_INCOMPLETE);
    for (const suffix of binding.appends) {
      const suffixValues = values(suffix, seenBindings);
      const hasSuffix = [...suffixValues].some((value) =>
        typeof value === 'string');
      if (!hasSuffix &&
        !suffixValues.has(STATIC_STRING_INCOMPLETE)) {
        continue;
      }
      if (![...resolved].some((value) => typeof value === 'string')) {
        resolved.add(STATIC_STRING_INCOMPLETE);
      }
      const appended = combineValues(
        new Set(resolved),
        suffixValues,
        preservedFragments
      );
      addValues(resolved, appended, preservedFragments);
    }
    seenBindings.delete(binding);
    return resolved;
  }

  return values;
}
