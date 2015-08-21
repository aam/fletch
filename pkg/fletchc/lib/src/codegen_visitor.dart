// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library fletchc.codegen_visitor;

import 'package:compiler/src/resolution/semantic_visitor.dart';

import 'package:compiler/src/resolution/operators.dart' show
    AssignmentOperator,
    BinaryOperator,
    IncDecOperator,
    UnaryOperator;

import 'package:compiler/src/constants/expressions.dart' show
    BoolFromEnvironmentConstantExpression,
    IntFromEnvironmentConstantExpression,
    StringFromEnvironmentConstantExpression,
    ConstantExpression,
    ConstructedConstantExpression,
    TypeConstantExpression;

import 'package:compiler/src/dart2jslib.dart' show
    CodegenRegistry,
    MessageKind,
    Registry;

import 'package:compiler/src/util/util.dart' show
    Link;

import 'package:compiler/src/elements/elements.dart';
import 'package:compiler/src/resolution/resolution.dart';
import 'package:compiler/src/tree/tree.dart';
import 'package:compiler/src/universe/universe.dart';
import 'package:compiler/src/util/util.dart' show Spannable;
import 'package:compiler/src/dart_types.dart';

import 'fletch_context.dart';

import 'fletch_backend.dart';

import 'fletch_constants.dart' show
    FletchFunctionBuilderConstant,
    FletchClassConstant,
    FletchClassInstanceConstant;

import 'fletch_function_builder.dart' show
    FletchFunctionBuilder;

import 'fletch_class_builder.dart' show
    FletchClassBuilder;

import 'fletch_selector.dart';

import '../fletch_system.dart';

import 'closure_environment.dart';

import '../incremental/fletchc_incremental.dart' show
    IncrementalCompilationFailed; // TODO(ahe): Remove this import.

enum VisitState {
  Value,
  Effect,
  Test,
}

/**
 * A reference to a local value, including how it should be used
 * (loaded/stored).
 */
abstract class LocalValue {
  final int slot;
  final Element element;
  LocalValue(this.slot, this.element);

  void initialize(BytecodeAssembler assembler);

  void load(BytecodeAssembler assembler);

  void store(BytecodeAssembler assembler);
}

/**
 * A reference to a local value that is boxed.
 */
class BoxedLocalValue extends LocalValue {
  BoxedLocalValue(int slot, Element element) : super(slot, element);

  void initialize(BytecodeAssembler assembler) {
    assembler.allocateBoxed();
  }

  void load(BytecodeAssembler assembler) {
    assembler.loadBoxedSlot(slot);
  }

  void store(BytecodeAssembler assembler) {
    assembler.storeBoxedSlot(slot);
  }

  String toString() => "Boxed($element, $slot)";
}

/**
 * A reference to a local value that is boxed.
 */
class UnboxedLocalValue extends LocalValue {
  UnboxedLocalValue(int slot, Element element) : super(slot, element);

  void initialize(BytecodeAssembler assembler) {}

  void load(BytecodeAssembler assembler) {
    assembler.loadSlot(slot);
  }

  void store(BytecodeAssembler assembler) {
    assembler.storeSlot(slot);
  }

  String toString() => "Local($element, $slot)";
}

class JumpInfo {
  final int stackSize;
  final BytecodeLabel continueLabel;
  final BytecodeLabel breakLabel;
  JumpInfo(this.stackSize, this.continueLabel, this.breakLabel);
}

class TryBlock {
  final int stackSize;
  final BytecodeLabel finallyLabel;
  final BytecodeLabel finallyReturnLabel;
  TryBlock(this.stackSize, this.finallyLabel, this.finallyReturnLabel);
}

abstract class CodegenVisitor
    extends SemanticVisitor
    with GetBulkMixin,
         SetBulkMixin,
         ErrorBulkMixin,
         InvokeBulkMixin,
         IndexSetBulkMixin,
         CompoundBulkMixin,
         UnaryBulkMixin,
         BaseBulkMixin,
         BinaryBulkMixin,
         PrefixBulkMixin,
         PostfixBulkMixin,
         NewBulkMixin,
         VariableBulkMixin,
         ParameterBulkMixin,
         FunctionBulkMixin,
         ConstructorBulkMixin,
         InitializerBulkMixin,
         BaseImplementationOfStaticsMixin,
         BaseImplementationOfLocalsMixin
    implements SemanticSendVisitor, SemanticDeclarationVisitor {
  // A literal int can have up to 31 bits of information (32 minus sign).
  static const int LITERAL_INT_MAX = 0x3FFFFFFF;

  final FletchContext context;

  final CodegenRegistry registry;

  final ClosureEnvironment closureEnvironment;

  final ExecutableElement element;

  final MemberElement member;

  final FletchFunctionBuilder functionBuilder;

  final Map<Element, LocalValue> scope = <Element, LocalValue>{};

  final Map<Node, JumpInfo> jumpInfo = <Node, JumpInfo>{};

  // Stack of try blocks (inner-most first), in the lexical scope.
  Link<TryBlock> tryBlockStack = const Link<TryBlock>();

  VisitState visitState;
  BytecodeLabel trueLabel;
  BytecodeLabel falseLabel;

  // TODO(ajohnsen): Merge computation into constructor.
  // The slot at which 'this' is stored. In closures, this is overwritten.
  LocalValue thisValue;

  List<Element> blockLocals = <Element>[];

  CodegenVisitor(FletchFunctionBuilder functionBuilder,
                 this.context,
                 TreeElements elements,
                 this.registry,
                 this.closureEnvironment,
                 this.element)
      : super(elements),
        this.functionBuilder = functionBuilder,
        thisValue = new UnboxedLocalValue(
            -1 - functionBuilder.assembler.functionArity,
            null);

  BytecodeAssembler get assembler => functionBuilder.assembler;

  SemanticSendVisitor get sendVisitor => this;
  SemanticDeclarationVisitor get declVisitor => this;

  void compile();

  ConstantExpression compileConstant(
      Node node,
      {TreeElements elements,
       bool isConst}) {
    if (elements == null) elements = this.elements;
    return context.compileConstant(node, elements, isConst: isConst);
  }

  int allocateConstantFromNode(Node node, {TreeElements elements}) {
    ConstantExpression expression = compileConstant(
        node,
        elements: elements,
        isConst: false);
    return functionBuilder.allocateConstant(
        context.getConstantValue(expression));
  }

  int allocateConstantClassInstance(int classId) {
    var constant = new FletchClassInstanceConstant(classId);
    context.markConstantUsed(constant);
    return functionBuilder.allocateConstant(constant);
  }

  int allocateStringConstant(String string) {
    return functionBuilder.allocateConstant(
        context.backend.constantSystem.createString(
            new DartString.literal(string)));
  }

  ClosureInfo get closureInfo => closureEnvironment.closures[element];

  LocalValue createLocalValueFor(
      LocalElement element,
      [int slot]) {
    if (slot == null) slot = assembler.stackSize;
    if (closureEnvironment.shouldBeBoxed(element)) {
      return new BoxedLocalValue(slot, element);
    }
    return new UnboxedLocalValue(slot, element);
  }

  LocalValue createLocalValueForParameter(
      ParameterElement parameter,
      int slot,
      {bool isCapturedArgumentsBoxed: false}) {
    // TODO(kasperl): Use [ParameterElement.constant] instead when
    // [ConstantValue] can be computed on-the-fly from a [ConstantExpression].
    Expression initializer = parameter.initializer;
    if (initializer != null) {
      // If the parameter has an initializer expression, we ask the context
      // to compile it right away to make sure we enqueue all dependent
      // elements correctly before we start assembling the program.
      context.compileConstant(
            initializer,
            parameter.memberContext.resolvedAst.elements,
            isConst: true);
    }

    if (closureEnvironment.shouldBeBoxed(parameter)) {
      if (isCapturedArgumentsBoxed) return new BoxedLocalValue(slot, parameter);
      LocalValue value = new BoxedLocalValue(assembler.stackSize, parameter);
      assembler.loadSlot(slot);
      value.initialize(assembler);
      return value;
    }
    return new UnboxedLocalValue(slot, parameter);
  }

  void pushVariableDeclaration(LocalValue value) {
    scope[value.element] = value;
  }

  void popVariableDeclaration(Element local) {
    scope.remove(local);
  }

  void registerDynamicInvocation(Selector selector) {
    registry.registerDynamicInvocation(new UniverseSelector(selector, null));
  }

  void registerDynamicGetter(Selector selector) {
    registry.registerDynamicGetter(new UniverseSelector(selector, null));
  }

  void registerDynamicSetter(Selector selector) {
    registry.registerDynamicSetter(new UniverseSelector(selector, null));
  }

  void registerStaticInvocation(FunctionElement function) {
    registry.registerStaticInvocation(function);
  }

  void registerInstantiatedClass(ClassElement klass) {
    registry.registerInstantiatedClass(klass);
  }

  void invokeMethod(Node node, Selector selector) {
    registerDynamicInvocation(selector);
    String symbol = context.getSymbolFromSelector(selector);
    int id = context.getSymbolId(symbol);
    int arity = selector.argumentCount;
    int fletchSelector = FletchSelector.encodeMethod(id, arity);
    assembler.invokeMethod(fletchSelector, arity, selector.name);
  }

  void invokeGetter(Node node, Selector selector) {
    registerDynamicGetter(selector);
    String symbol = context.getSymbolFromSelector(selector);
    int id = context.getSymbolId(symbol);
    int fletchSelector = FletchSelector.encodeGetter(id);
    assembler.invokeMethod(fletchSelector, 0);
  }

  void invokeSetter(Node node, Selector selector) {
    registerDynamicSetter(selector);
    String symbol = context.getSymbolFromSelector(selector);
    int id = context.getSymbolId(symbol);
    int fletchSelector = FletchSelector.encodeSetter(id);
    assembler.invokeMethod(fletchSelector, 1);
  }

  void invokeFactory(Node node, int constId, int arity) {
    assembler.invokeFactory(constId, arity);
  }

  void invokeStatic(Node node, int constId, int arity) {
    assembler.invokeStatic(constId, arity);
  }

  void generateIdentical(Node node) {
    assembler.identical();
  }

  void generateIdenticalNonNumeric(Node node) {
    assembler.identicalNonNumeric();
  }

  void generateReturn(Node node) {
    assembler.ret();
  }

  void generateSwitchCaseMatch(CaseMatch caseMatch, BytecodeLabel ifTrue) {
    assembler.dup();
    int constId = allocateConstantFromNode(caseMatch.expression);
    assembler.loadConst(constId);
    // For debugging, ignore the equality checks in connection
    // with case matches by not associating the calls with
    // any node.
    invokeMethod(null, new Selector.binaryOperator('=='));
    assembler.branchIfTrue(ifTrue);
  }

  FletchFunctionBase requireFunction(FunctionElement element) {
    registerStaticInvocation(element);
    return context.backend.getFunctionForElement(element);
  }

  void doStaticFunctionInvoke(
      Node node,
      FletchFunctionBase function,
      NodeList arguments,
      CallStructure callStructure,
      {bool factoryInvoke: false}) {
    if (function.isInstanceMember) loadThis();
    FunctionSignature signature = function.signature;
    int functionId;
    int arity;
    if (signature.hasOptionalParameters &&
        signature.optionalParametersAreNamed) {
      if (FletchBackend.isExactParameterMatch(signature, callStructure)) {
        functionId = function.functionId;
      } else if (callStructure.signatureApplies(signature)) {
        // TODO(ajohnsen): Inline parameter stub?
        FletchFunctionBase stub = context.backend.createParameterStubFor(
            function,
            callStructure.callSelector);
        functionId = stub.functionId;
      } else {
        doUnresolved(function.name);
        return;
      }
      for (Node argument in arguments) {
        visitForValue(argument);
      }
      arity = callStructure.argumentCount;
    } else if (callStructure != null &&
               callStructure.namedArguments.isNotEmpty) {
      doUnresolved(function.name);
      return;
    } else {
      functionId = function.functionId;
      arity = loadPositionalArguments(arguments, signature, function.name);
    }
    if (function.isInstanceMember) arity++;
    int constId = functionBuilder.allocateConstantFromFunction(functionId);
    if (factoryInvoke) {
      invokeFactory(node, constId, arity);
    } else {
      invokeStatic(node, constId, arity);
    }
  }

  void loadThis() {
    thisValue.load(assembler);
  }

  /**
   * Load the [arguments] for caling [function], with potential positional
   * arguments.
   *
   * Return the number of arguments pushed onto the stack.
   */
  int loadPositionalArguments(
      NodeList arguments,
      FunctionSignature signature,
      String name) {
    int argumentCount = 0;
    Iterator<Node> it = arguments.iterator;
    signature.orderedForEachParameter((ParameterElement parameter) {
      if (it.moveNext()) {
        visitForValue(it.current);
      } else {
        if (parameter.isOptional) {
          doParameterInitializer(parameter);
        } else {
          doUnresolved(name);
        }
      }
      argumentCount++;
    });
    if (it.moveNext()) doUnresolved(name);
    return argumentCount;
  }

  void doParameterInitializer(ParameterElement parameter) {
    Expression initializer = parameter.initializer;
    if (initializer == null) {
      assembler.loadLiteralNull();
    } else {
      int constId = allocateConstantFromNode(
          initializer,
          elements: parameter.resolvedAst.elements);
      assembler.loadConst(constId);
    }
  }

  void doVisitForValue(Node node) {
    VisitState oldState = visitState;
    visitState = VisitState.Value;
    node.accept(this);
    visitState = oldState;
  }

  // Visit the expression [node] and push the result on top of the stack.
  void visitForValue(Node node) {
    doVisitForValue(node);
  }

  // Visit the expression [node] and push the result on top of the stack.
  // This method bypasses debug information collection and using this
  // method will not generate breakpoints for the expression evaluation.
  // This is useful when dealing with internal details that the programmer
  // shouldn't care about such as the string concatenation aspects of
  // of string interpolation.
  void visitForValueNoDebugInfo(Node node) {
    doVisitForValue(node);
  }

  // Visit the expression [node] without pushing the result on top of the stack.
  void visitForEffect(Node node) {
    VisitState oldState = visitState;
    visitState = VisitState.Effect;
    node.accept(this);
    visitState = oldState;
  }

  // Visit the expression [node] with the result being a branch to either
  // [trueLabel] or [falseLabel].
  void visitForTest(
      Node node,
      BytecodeLabel trueLabel,
      BytecodeLabel falseLabel) {
    VisitState oldState = visitState;
    visitState = VisitState.Test;
    BytecodeLabel oldTrueLabel = this.trueLabel;
    this.trueLabel = trueLabel;
    BytecodeLabel oldFalseLabel = this.falseLabel;
    this.falseLabel = falseLabel;
    node.accept(this);
    visitState = oldState;
    this.trueLabel = oldTrueLabel;
    this.falseLabel = oldFalseLabel;
  }

  void applyVisitState() {
    if (visitState == VisitState.Effect) {
      assembler.pop();
    } else if (visitState == VisitState.Test) {
      assembler.branchIfTrue(trueLabel);
      assembler.branch(falseLabel);
    }
  }

  void visitNamedArgument(NamedArgument node) {
    Expression expression = node.expression;
    if (expression != null) {
      visitForValue(expression);
    } else {
      assembler.loadLiteralNull();
    }
    applyVisitState();
  }

  void doLocalVariableCompound(
      Node node,
      LocalVariableElement variable,
      AssignmentOperator operator,
      Node rhs) {
    LocalValue value = scope[variable];
    value.load(assembler);
    visitForValue(rhs);
    String operatorName = operator.binaryOperator.name;
    invokeMethod(node, new Selector.binaryOperator(operatorName));
    value.store(assembler);
  }

  void visitLocalVariableCompound(
      Send node,
      LocalVariableElement variable,
      AssignmentOperator operator,
      Node rhs,
      _) {
    doLocalVariableCompound(node, variable, operator, rhs);
    applyVisitState();
  }

  void visitParameterCompound(
      Send node,
      LocalParameterElement parameter,
      AssignmentOperator operator,
      Node rhs,
      _) {
    doLocalVariableCompound(node, parameter, operator, rhs);
    applyVisitState();
  }

  void doStaticFieldCompound(
      Node node,
      FieldElement field,
      AssignmentOperator operator,
      Node rhs) {
    doStaticFieldGet(field);
    visitForValue(rhs);
    Selector selector = new Selector.binaryOperator(
        operator.binaryOperator.name);
    invokeMethod(node, selector);
    doStaticFieldSet(field);
  }

  void visitTopLevelFieldCompound(
      Send node,
      FieldElement field,
      AssignmentOperator operator,
      Node rhs,
      _) {
    doStaticFieldCompound(node, field, operator, rhs);
    applyVisitState();
  }

  void visitStaticFieldCompound(
      Send node,
      FieldElement field,
      AssignmentOperator operator,
      Node rhs,
      _) {
    doStaticFieldCompound(node, field, operator, rhs);
    applyVisitState();
  }

  void doBinaryOperator(
      Node node,
      Node left,
      Node right,
      BinaryOperator operator) {
    bool isConstNull(Node node) {
      ConstantExpression expression = compileConstant(node, isConst: false);
      if (expression == null) return false;
      return context.getConstantValue(expression).isNull;
    }

    visitForValue(left);
    visitForValue(right);
    // For '==', if either side is a null literal, use identicalNonNumeric.
    if (operator == BinaryOperator.EQ &&
        (isConstNull(left) || isConstNull(right))) {
      generateIdenticalNonNumeric(node);
      return;
    }

    Selector selector = new Selector.binaryOperator(operator.name);
    invokeMethod(node, selector);
  }

  void visitEquals(
      Send node,
      Node left,
      Node right,
      _) {
    // TODO(ajohnsen): Inject null check (in callee).
    doBinaryOperator(node, left, right, BinaryOperator.EQ);
    applyVisitState();
  }

  void visitNotEquals(
      Send node,
      Node left,
      Node right,
      _) {
    doBinaryOperator(node, left, right, BinaryOperator.EQ);
    if (visitState == VisitState.Test) {
      assembler.branchIfTrue(falseLabel);
      assembler.branch(trueLabel);
    } else {
      assembler.negate();
      applyVisitState();
    }
  }

  void visitBinary(
      Send node,
      Node left,
      BinaryOperator operator,
      Node right,
      _) {
    doBinaryOperator(node, left, right, operator);
    applyVisitState();
  }

  void visitUnary(
      Send node,
      UnaryOperator operator,
      Node value,
      _) {
    visitForValue(value);
    Selector selector = new Selector.unaryOperator(operator.name);
    invokeMethod(node, selector);
    applyVisitState();
  }

  void visitNot(
      Send node,
      Node value,
      _) {
    visitForValue(value);
    assembler.negate();
    applyVisitState();
  }

  void visitIndex(
      Send node,
      Node receiver,
      Node index,
      _) {
    visitForValue(receiver);
    visitForValue(index);
    Selector selector = new Selector.index();
    invokeMethod(node, selector);
    applyVisitState();
  }

  void visitIndexSet(
      SendSet node,
      Node receiver,
      Node index,
      Node value,
      _) {
    visitForValue(receiver);
    visitForValue(index);
    visitForValue(value);
    Selector selector = new Selector.indexSet();
    invokeMethod(node, selector);
    applyVisitState();
  }

  void visitLogicalAnd(
      Send node,
      Node left,
      Node right,
      _) {
    if (visitState == VisitState.Test) {
      BytecodeLabel isFirstTrue = new BytecodeLabel();
      visitForTest(left, isFirstTrue, falseLabel);
      assembler.bind(isFirstTrue);
      visitForTest(right, trueLabel, falseLabel);
      return;
    }

    BytecodeLabel isFirstTrue = new BytecodeLabel();
    BytecodeLabel isTrue = new BytecodeLabel();
    BytecodeLabel isFalse = new BytecodeLabel();

    assembler.loadLiteralFalse();

    visitForTest(left, isFirstTrue, isFalse);

    assembler.bind(isFirstTrue);
    visitForTest(right, isTrue, isFalse);

    assembler.bind(isTrue);
    assembler.pop();
    assembler.loadLiteralTrue();
    assembler.bind(isFalse);

    applyVisitState();
  }

  void visitLogicalOr(
      Send node,
      Node left,
      Node right,
      _) {
    if (visitState == VisitState.Test) {
      BytecodeLabel isFirstFalse = new BytecodeLabel();
      visitForTest(left, trueLabel, isFirstFalse);
      assembler.bind(isFirstFalse);
      visitForTest(right, trueLabel, falseLabel);
      return;
    }

    BytecodeLabel isFirstFalse = new BytecodeLabel();
    BytecodeLabel isTrue = new BytecodeLabel();
    BytecodeLabel isFalse = new BytecodeLabel();

    assembler.loadLiteralTrue();

    visitForTest(left, isTrue, isFirstFalse);

    assembler.bind(isFirstFalse);
    visitForTest(right, isTrue, isFalse);

    assembler.bind(isFalse);
    assembler.pop();
    assembler.loadLiteralFalse();
    assembler.bind(isTrue);

    applyVisitState();
  }

  void visitConditional(Conditional node) {
    BytecodeLabel isTrue = new BytecodeLabel();
    BytecodeLabel isFalse = new BytecodeLabel();
    BytecodeLabel done = new BytecodeLabel();

    assembler.loadLiteralNull();

    visitForTest(node.condition, isTrue, isFalse);

    assembler.bind(isTrue);
    assembler.pop();
    visitForValue(node.thenExpression);
    assembler.branch(done);

    assembler.bind(isFalse);
    assembler.pop();
    visitForValue(node.elseExpression);

    assembler.bind(done);

    applyVisitState();
  }

  void callIsSelector(
      Node node,
      DartType type,
      // TODO(ahe): Remove [diagnosticLocation] when malformed types are
      // handled.
      Spannable diagnosticLocation) {
    if (type == null || type.isMalformed) {
      assembler.pop();
      generateUnimplementedError(
          diagnosticLocation, "Unhandled type test for malformed $type.");
      return;
    }

    if (type.isDynamic) {
      assembler.pop();
      assembler.loadLiteralTrue();
      return;
    }

    if (type.isTypedef) {
      // TODO(ajohnsen): This only matches with the number of arguments, not
      // the actual argument types.
      TypedefType typedefType = type;
      int arity = typedefType.element.functionSignature.parameterCount;
      int fletchSelector = context.toFletchIsSelector(
          context.backend.compiler.functionClass, arity);
      assembler.invokeTest(fletchSelector, 0);
      return;
    }

    if (!type.isInterfaceType) {
      assembler.pop();
      generateUnimplementedError(
          diagnosticLocation, "Unhandled type test for $type.");
      return;
    }

    Element element = type.element;
    int fletchSelector = context.toFletchIsSelector(element);
    assembler.invokeTest(fletchSelector, 0);
  }

  void doIs(
      Node node,
      Node expression,
      DartType type,
      // TODO(ahe): Remove [diagnosticLocation] when callIsSelector does not
      // require it.
      Spannable diagnosticLocation) {
    visitForValue(expression);
    callIsSelector(node, type, diagnosticLocation);
  }

  void visitIs(
      Send node,
      Node expression,
      DartType type,
      _) {
    doIs(node, expression, type, node.arguments.first);
    applyVisitState();
  }

  void visitIsNot(
      Send node,
      Node expression,
      DartType type,
      _) {
    doIs(node, expression, type, node.arguments.first);
    assembler.negate();
    applyVisitState();
  }

  void visitAs(
      Send node,
      Node expression,
      DartType type,
      _) {
    // TODO(ajohnsen): To actual type check.
    visitForValue(expression);
    applyVisitState();
  }

  void visitThisGet(
      Node node,
      _) {
    loadThis();
    applyVisitState();
  }

  void doIdenticalCall(Node node, NodeList arguments) {
    assert(arguments.slowLength() == 2);
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    generateIdentical(node);
  }

  void handleStaticFunctionGet(
      Send node,
      MethodElement function,
      _) {
    FletchFunctionBase target = requireFunction(function);
    FletchClassBuilder classBuilder =
        context.backend.createTearoffClass(target);
    assert(classBuilder.fields == 0);
    int constId = allocateConstantClassInstance(classBuilder.classId);
    assembler.loadConst(constId);
    applyVisitState();
  }

  void doMainCall(Send node, NodeList arguments) {
    FunctionElement function = context.compiler.mainFunction;
    if (function.isErroneous) {
      doCompileError();
      return;
    }
    if (context.compiler.libraryLoader.libraries.any(checkCompileError)) return;

    // Load up to 'parameterCount' arguments, padding with nulls.
    int parameterCount = function.functionSignature.parameterCount;
    int argumentCount = 0;
    for (Node argument in arguments) {
      if (argumentCount == parameterCount) break;
      visitForValue(argument);
      argumentCount++;
    }
    for (int i = argumentCount; i < parameterCount; i++) {
      assembler.loadLiteralNull();
    }

    FletchFunctionBase base = requireFunction(function);
    int constId = functionBuilder.allocateConstantFromFunction(base.functionId);
    invokeStatic(node, constId, parameterCount);
  }

  void doStaticallyBoundInvoke(
      Send node,
      MethodElement element,
      NodeList arguments,
      CallStructure callStructure) {
    if (checkCompileError(element)) return;
    if (element.declaration == context.compiler.identicalFunction) {
      doIdenticalCall(node, arguments);
      return;
    }
    if (element.isExternal) {
      // Patch known functions directly.
      if (element == context.backend.fletchExternalInvokeMain) {
        doMainCall(node, arguments);
        return;
      } else if (element == context.backend.fletchExternalCoroutineChange) {
        for (Node argument in arguments) {
          visitForValue(argument);
        }
        assembler.coroutineChange();
        return;
      }
      // TODO(ajohnsen): Define a known set of external functions we allow
      // calls to?
    }
    FletchFunctionBase target = requireFunction(element);
    doStaticFunctionInvoke(node, target, arguments, callStructure);
  }

  void handleStaticFunctionInvoke(
      Send node,
      MethodElement element,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    doStaticallyBoundInvoke(
        node, element.declaration, arguments, callStructure);
    applyVisitState();
  }

  void visitSuperMethodInvoke(
      Send node,
      MethodElement element,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    doStaticallyBoundInvoke(node, element, arguments, callStructure);
    applyVisitState();
  }

  void doSuperCall(Node node, FunctionElement function) {
    registerStaticInvocation(function);
    int arity = function.functionSignature.parameterCount + 1;
    FletchFunctionBase base = requireFunction(function);
    int constId = functionBuilder.allocateConstantFromFunction(base.functionId);
    invokeStatic(node, constId, arity);
  }

  void visitSuperGetterGet(
      Send node,
      FunctionElement getter,
      _) {
    loadThis();
    doSuperCall(node, getter);
    applyVisitState();
  }

  void visitSuperMethodGet(
      Send node,
      MethodElement method,
      _) {
    loadThis();
    FletchFunctionBase target = requireFunction(method);
    FletchClassBuilder classBuilder =
        context.backend.createTearoffClass(target);
    assert(classBuilder.fields == 1);
    int constId = functionBuilder.allocateConstantFromClass(
        classBuilder.classId);
    assembler.allocate(constId, classBuilder.fields);
    applyVisitState();
  }

  void visitSuperSetterSet(
      SendSet node,
      FunctionElement setter,
      Node rhs,
      _) {
    loadThis();
    visitForValue(rhs);
    doSuperCall(node, setter);
    applyVisitState();
  }

  void visitSuperIndex(
      Send node,
      FunctionElement function,
      Node index,
      _) {
    loadThis();
    visitForValue(index);
    doSuperCall(node, function);
    applyVisitState();
  }

  void visitSuperIndexSet(
      Send node,
      FunctionElement function,
      Node index,
      Node rhs,
      _) {
    loadThis();
    visitForValue(index);
    visitForValue(rhs);
    doSuperCall(node, function);
    applyVisitState();
  }

  void visitSuperCompoundIndexSet(
      Send node,
      FunctionElement getter,
      FunctionElement setter,
      Node index,
      AssignmentOperator operator,
      Node rhs,
      _) {
    visitForValue(index);
    loadThis();
    assembler.loadLocal(1);
    doSuperCall(node, getter);
    loadThis();
    // Load index
    assembler.loadLocal(2);
    // Load value from index call and call operator.
    assembler.loadLocal(2);
    visitForValue(rhs);
    invokeMethod(node, getAssignmentSelector(operator));
    doSuperCall(node, setter);
    // Override 'index' with result value, and pop everything else.
    assembler.storeLocal(2);
    assembler.pop();
    assembler.pop();
    applyVisitState();
  }

  void visitSuperIndexPostfix(
      SendSet node,
      FunctionElement getter,
      FunctionElement setter,
      Node index,
      IncDecOperator operator,
      _) {
    // TODO(ajohnsen): Fast-case when for effect.
    visitForValue(index);
    loadThis();
    assembler.loadLocal(1);
    doSuperCall(node, getter);
    loadThis();
    // Load index
    assembler.loadLocal(2);
    // Load value from index call and inc/dec.
    assembler.loadLocal(2);
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    // We can now call []= with 'this', 'index' and 'value'.
    doSuperCall(node, setter);
    assembler.pop();
    // Pop result, override 'index' with initial indexed value, and pop again.
    assembler.storeLocal(1);
    assembler.pop();
    applyVisitState();
  }

  void visitSuperBinary(
      Send node,
      FunctionElement function,
      BinaryOperator operator,
      Node argument,
      _) {
    loadThis();
    visitForValue(argument);
    doSuperCall(node, function);
    applyVisitState();
  }

  void visitSuperEquals(
      Send node,
      FunctionElement function,
      Node argument,
      _) {
    loadThis();
    visitForValue(argument);
    doSuperCall(node, function);
    applyVisitState();
  }

  void visitSuperUnary(
      Send node,
      UnaryOperator operator,
      FunctionElement function,
      _) {
    loadThis();
    doSuperCall(node, function);
    applyVisitState();
  }

  int computeFieldIndex(FieldElement field) {
    ClassElement classElement = element.enclosingClass;
    int fieldIndex;
    FletchClassBuilder classBuilder;
    do {
      // We need to find the mixin application of the class, where the field
      // is stored. Iterate until it's found.
      classBuilder = context.backend.registerClassElement(classElement);
      classElement = classElement.implementation;
      int i = 0;
      classElement.forEachInstanceField((_, FieldElement member) {
        if (member == field) {
          assert(fieldIndex == null);
          fieldIndex = i;
        }
        i++;
      });
      classElement = classElement.superclass;
    } while (fieldIndex == null);
    fieldIndex += classBuilder.superclassFields;
    return fieldIndex;
  }

  void visitSuperFieldGet(
      Send node,
      FieldElement field,
      _) {
    loadThis();
    assembler.loadField(computeFieldIndex(field));
    applyVisitState();
  }

  void visitSuperFieldSet(
      SendSet node,
      FieldElement field,
      Node rhs,
      _) {
    loadThis();
    visitForValue(rhs);
    assembler.storeField(computeFieldIndex(field));
    applyVisitState();
  }

  void handleStaticFieldInvoke(
      Node node,
      FieldElement field,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    doStaticFieldGet(field);
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, callStructure.callSelector);
    applyVisitState();
  }

  void visitDynamicPropertyInvoke(
      Send node,
      Node receiver,
      NodeList arguments,
      Selector selector,
      _) {
    if (selector == null) {
      // TODO(ajohnsen): Remove hack - dart2js has a problem with generating
      // selectors in initializer bodies.
      selector = new Selector.call(
          node.selector.asIdentifier().source,
          element.library,
          arguments.slowLength());
    }
    visitForValue(receiver);
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, selector);
    applyVisitState();
  }

  void visitExpressionInvoke(
      Send node,
      Expression receiver,
      NodeList arguments,
      Selector selector,
      _) {
    visitForValue(receiver);
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, selector);
    applyVisitState();
  }

  void visitThisPropertyInvoke(
      Send node,
      NodeList arguments,
      Selector selector,
      _) {
    loadThis();

    // If the property is statically known to be a field, instead invoke the
    // getter and then invoke 'call(...)' on the value.
    // TODO(ajohnsen): This is a fix that only works when the field is
    // statically known - that is not always the case. Implement VM support?
    Element target = elements[node];
    if (target != null && target.isField) {
      invokeGetter(node, new Selector.getter(target.name, element.library));
      selector = new Selector.callClosureFrom(selector);
    }
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, selector);
    applyVisitState();
  }

  void visitThisInvoke(
      Send node,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    loadThis();
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, callStructure.callSelector);
    applyVisitState();
  }

  void visitClassTypeLiteralGet(
      Send node,
      ConstantExpression constant,
      _) {
    generateUnimplementedError(
        node, "[visitClassTypeLiteralGet] isn't implemented.");
    applyVisitState();
  }

  void visitDynamicPropertyGet(
      Send node,
      Node receiver,
      Selector selector,
      _) {
    if (selector == null) {
      // TODO(ajohnsen): Remove hack - dart2js has a problem with generating
      // selectors in initializer bodies.
      selector = new Selector.getter(
          node.selector.asIdentifier().source,
          element.library);
    }
    visitForValue(receiver);
    invokeGetter(node, selector);
    applyVisitState();
  }

  void visitThisPropertyGet(
      Send node,
      Selector selector,
      _) {
    loadThis();
    invokeGetter(node, selector);
    applyVisitState();
  }

  void visitThisPropertySet(
      Send node,
      Selector selector,
      Node rhs,
      _) {
    loadThis();
    visitForValue(rhs);
    invokeSetter(node, selector);
    applyVisitState();
  }

  void doStaticFieldGet(FieldElement field) {
    if (checkCompileError(field)) return;
    if (field.isConst) {
      int constId = allocateConstantFromNode(
          field.initializer,
          elements: field.resolvedAst.elements);
      assembler.loadConst(constId);
    } else {
      int index = context.backend.compileLazyFieldInitializer(field, registry);
      if (field.initializer != null) {
        assembler.loadStaticInit(index);
      } else {
        assembler.loadStatic(index);
      }
    }
  }

  void handleStaticFieldGet(
      Send node,
      FieldElement field,
      _) {
    doStaticFieldGet(field);
    applyVisitState();
  }

  void visitAssert(Send node, Node expression, _) {
    // TODO(ajohnsen): Emit assert in checked mode.
  }

  void visitDynamicPropertySet(
      Send node,
      Node receiver,
      Selector selector,
      Node rhs,
      _) {
    visitForValue(receiver);
    visitForValue(rhs);
    invokeSetter(node, selector);
    applyVisitState();
  }

  void doStaticFieldSet(FieldElement field) {
    int index = context.getStaticFieldIndex(field, element);
    assembler.storeStatic(index);
  }

  void handleStaticFieldSet(
      SendSet node,
      FieldElement field,
      Node rhs,
      _) {
    visitForValue(rhs);
    doStaticFieldSet(field);
    applyVisitState();
  }

  void visitStringJuxtaposition(StringJuxtaposition node) {
    // TODO(ajohnsen): This could probably be optimized to string constants in
    // some cases.
    visitForValue(node.first);
    visitForValue(node.second);
    // TODO(ajohnsen): Cache these in context/backend.
    Selector concat = new Selector.binaryOperator('+');
    invokeMethod(node, concat);
    applyVisitState();
  }

  void visitStringInterpolation(StringInterpolation node) {
    // TODO(ajohnsen): Cache these in context/backend.
    Selector toString = new Selector.call('toString', null, 0);
    Selector concat = new Selector.binaryOperator('+');
    visitForValueNoDebugInfo(node.string);
    for (StringInterpolationPart part in node.parts) {
      visitForValue(part.expression);
      invokeMethod(part.expression, toString);
      LiteralString string = part.string;
      if (string.dartString.isNotEmpty) {
        visitForValueNoDebugInfo(string);
        invokeMethod(null, concat);
      }
      invokeMethod(null, concat);
    }
    applyVisitState();
  }

  void visitLiteralNull(LiteralNull node) {
    if (visitState == VisitState.Value) {
      assembler.loadLiteralNull();
    } else if (visitState == VisitState.Test) {
      assembler.branch(falseLabel);
    }
  }

  void visitLiteralSymbol(LiteralSymbol node) {
    int constId = allocateConstantFromNode(node);
    assembler.loadConst(constId);
    applyVisitState();
  }

  void visitLiteralBool(LiteralBool node) {
    var expression = compileConstant(node, isConst: false);
    bool isTrue = expression != null &&
        context.getConstantValue(expression).isTrue;

    if (visitState == VisitState.Value) {
      if (isTrue) {
        assembler.loadLiteralTrue();
      } else {
        assembler.loadLiteralFalse();
      }
    } else if (visitState == VisitState.Test) {
      assembler.branch(isTrue ? trueLabel : falseLabel);
    }
  }

  void visitLiteralInt(LiteralInt node) {
    if (visitState == VisitState.Value) {
      int value = node.value;
      assert(value >= 0);
      if (value > LITERAL_INT_MAX) {
        int constId = allocateConstantFromNode(node);
        assembler.loadConst(constId);
      } else {
        assembler.loadLiteral(value);
      }
    } else if (visitState == VisitState.Test) {
      assembler.branch(falseLabel);
    }
  }

  void visitLiteral(Literal node) {
    if (visitState == VisitState.Value) {
      assembler.loadConst(allocateConstantFromNode(node));
    } else if (visitState == VisitState.Test) {
      assembler.branch(falseLabel);
    }
  }

  void visitLiteralList(LiteralList node) {
    if (node.isConst) {
      int constId = allocateConstantFromNode(node);
      assembler.loadConst(constId);
      applyVisitState();
      return;
    }
    ClassElement literalClass = context.backend.growableListClass;
    ConstructorElement constructor = literalClass.lookupDefaultConstructor();
    if (constructor == null) {
      internalError(node, "Failed to lookup default list constructor");
    }
    // Call with empty arguments, as we call the default constructor.
    callConstructor(
        node, constructor, new NodeList.empty(), CallStructure.NO_ARGS);
    Selector add = new Selector.call('add', null, 1);
    for (Node element in node.elements) {
      assembler.dup();
      visitForValue(element);
      invokeMethod(node, add);
      assembler.pop();
    }
    applyVisitState();
  }

  void visitLiteralMap(LiteralMap node) {
    if (node.isConst) {
      int constId = allocateConstantFromNode(node);
      assembler.loadConst(constId);
      applyVisitState();
      return;
    }
    ClassElement literalClass = context.backend.mapImplementation;
    ConstructorElement constructor = literalClass.lookupDefaultConstructor();
    if (constructor == null) {
      internalError(literalClass, "Failed to lookup default map constructor");
      return;
    }
    // The default constructor is a redirecting factory constructor. Follow it.
    constructor = constructor.effectiveTarget;
    FletchFunctionBase function = requireFunction(constructor.declaration);
    doStaticFunctionInvoke(
        node,
        function,
        new NodeList.empty(),
        CallStructure.NO_ARGS,
        factoryInvoke: true);

    Selector selector = new Selector.indexSet();
    for (Node element in node.entries) {
      assembler.dup();
      visitForValue(element);
      invokeMethod(node, selector);
      assembler.pop();
    }
    applyVisitState();
  }

  void visitLiteralMapEntry(LiteralMapEntry node) {
    assert(visitState == VisitState.Value);
    visitForValue(node.key);
    visitForValue(node.value);
  }

  void visitLiteralString(LiteralString node) {
    if (visitState == VisitState.Value) {
      assembler.loadConst(allocateConstantFromNode(node));
      registerInstantiatedClass(
          context.compiler.backend.stringImplementation);
    } else if (visitState == VisitState.Test) {
      assembler.branch(falseLabel);
    }
  }

  void visitCascadeReceiver(CascadeReceiver node) {
    visitForValue(node.expression);
    assembler.dup();
    assert(visitState == VisitState.Value);
  }

  void visitCascade(Cascade node) {
    visitForEffect(node.expression);
    applyVisitState();
  }

  void visitParenthesizedExpression(ParenthesizedExpression node) {
    // Visit expression in the same VisitState.
    node.expression.accept(this);
  }

  void handleLocalGet(
      Send node,
      LocalElement element,
      _) {
    scope[element].load(assembler);
    applyVisitState();
  }

  void handleLocalSet(
      SendSet node,
      LocalElement element,
      Node rhs,
      _) {
    visitForValue(rhs);
    scope[element].store(assembler);
    applyVisitState();
  }

  void handleLocalInvoke(
      Node node,
      LocalElement element,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    scope[element].load(assembler);
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, callStructure.callSelector);
    applyVisitState();
  }

  static Selector getIncDecSelector(IncDecOperator operator) {
    String name = operator == IncDecOperator.INC ? '+' : '-';
    return new Selector.binaryOperator(name);
  }

  static Selector getAssignmentSelector(AssignmentOperator operator) {
    String name = operator.binaryOperator.name;
    return new Selector.binaryOperator(name);
  }

  void doLocalVariableIncrement(
      Node node,
      LocalVariableElement element,
      IncDecOperator operator,
      bool prefix) {
    // TODO(ajohnsen): Candidate for bytecode: Inc/Dec local with non-Smi
    // bailout.
    LocalValue value = scope[element];
    value.load(assembler);
    // For postfix, keep local, unmodified version, to 'return' after store.
    if (!prefix) assembler.dup();
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    value.store(assembler);
    if (!prefix) assembler.pop();
  }

  void visitLocalVariablePrefix(
      SendSet node,
      LocalVariableElement element,
      IncDecOperator operator,
      _) {
    doLocalVariableIncrement(node, element, operator, true);
    applyVisitState();
  }

  void visitParameterPrefix(
      Send node,
      LocalParameterElement parameter,
      IncDecOperator operator,
      _) {
    doLocalVariableIncrement(node, parameter, operator, true);
    applyVisitState();
  }

  void visitLocalVariablePostfix(
      SendSet node,
      LocalVariableElement element,
      IncDecOperator operator,
      _) {
    // If visitState is for effect, we can ignore the return value, thus always
    // generate code for the simpler 'prefix' case.
    bool prefix = (visitState == VisitState.Effect);
    doLocalVariableIncrement(node, element, operator, prefix);
    applyVisitState();
  }

  void visitParameterPostfix(
      SendSet node,
      LocalParameterElement parameter,
      IncDecOperator operator,
      _) {
    // If visitState is for effect, we can ignore the return value, thus always
    // generate code for the simpler 'prefix' case.
    bool prefix = (visitState == VisitState.Effect);
    doLocalVariableIncrement(node, parameter, operator, prefix);
    applyVisitState();
  }

  void doStaticFieldPrefix(
        Node node,
        FieldElement field,
        IncDecOperator operator) {
    doStaticFieldGet(field);
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    doStaticFieldSet(field);
  }

  void doStaticFieldPostfix(
        Node node,
        FieldElement field,
        IncDecOperator operator) {
    doStaticFieldGet(field);
    // For postfix, keep local, unmodified version, to 'return' after store.
    assembler.dup();
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    doStaticFieldSet(field);
    assembler.pop();
  }

  void visitStaticFieldPostfix(
      Send node,
      FieldElement field,
      IncDecOperator operator,
      _) {
    if (visitState == VisitState.Effect) {
      doStaticFieldPrefix(node, field, operator);
    } else {
      doStaticFieldPostfix(node, field, operator);
    }
    applyVisitState();
  }

  void visitStaticFieldPrefix(
      Send node,
      FieldElement field,
      IncDecOperator operator,
      _) {
    doStaticFieldPrefix(node, field, operator);
    applyVisitState();
  }

  void visitTopLevelFieldPostfix(
      Send node,
      FieldElement field,
      IncDecOperator operator,
      _) {
    if (visitState == VisitState.Effect) {
      doStaticFieldPrefix(node, field, operator);
    } else {
      doStaticFieldPostfix(node, field, operator);
    }
    applyVisitState();
  }

  void visitTopLevelFieldPrefix(
      Send node,
      FieldElement field,
      IncDecOperator operator,
      _) {
    doStaticFieldPrefix(node, field, operator);
    applyVisitState();
  }

  void doDynamicPropertyCompound(
      Node node,
      AssignmentOperator operator,
      Node rhs,
      Selector getterSelector,
      Selector setterSelector) {
    // Dup receiver for setter.
    assembler.dup();
    invokeGetter(node, getterSelector);
    visitForValue(rhs);
    invokeMethod(node, getAssignmentSelector(operator));
    invokeSetter(node, setterSelector);
  }

  void visitDynamicPropertyCompound(
      Send node,
      Node receiver,
      AssignmentOperator operator,
      Node rhs,
      Selector getterSelector,
      Selector setterSelector,
      _) {
    visitForValue(receiver);
    doDynamicPropertyCompound(
        node,
        operator,
        rhs,
        getterSelector,
        setterSelector);
    applyVisitState();
  }


  void visitThisPropertyCompound(
      Send node,
      AssignmentOperator operator,
      Node rhs,
      Selector getterSelector,
      Selector setterSelector,
      _) {
    loadThis();
    doDynamicPropertyCompound(
        node,
        operator,
        rhs,
        getterSelector,
        setterSelector);
    applyVisitState();
  }

  void doDynamicPrefix(
      Node node,
      IncDecOperator operator,
      Selector getterSelector,
      Selector setterSelector) {
    assembler.dup();
    invokeGetter(node, getterSelector);
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    invokeSetter(node, setterSelector);
  }

  void doIndexPrefix(
      SendSet node,
      Node receiver,
      Node index,
      IncDecOperator operator) {
    visitForValue(receiver);
    visitForValue(index);
    // Load already evaluated receiver and index for '[]' call.
    assembler.loadLocal(1);
    assembler.loadLocal(1);
    invokeMethod(node, new Selector.index());
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    // Use existing evaluated receiver and index for '[]=' call.
    invokeMethod(node, new Selector.indexSet());
  }

  void visitIndexPrefix(
      SendSet node,
      Node receiver,
      Node index,
      IncDecOperator operator,
      _) {
    doIndexPrefix(node, receiver, index, operator);
    applyVisitState();
  }

  void visitIndexPostfix(
      Send node,
      Node receiver,
      Node index,
      IncDecOperator operator,
      _) {
    if (visitState == VisitState.Effect) {
      doIndexPrefix(node, receiver, index, operator);
      applyVisitState();
      return;
    }

    // Reserve slot for result.
    assembler.loadLiteralNull();
    visitForValue(receiver);
    visitForValue(index);
    // Load already evaluated receiver and index for '[]' call.
    assembler.loadLocal(1);
    assembler.loadLocal(1);
    invokeMethod(node, new Selector.index());
    assembler.storeLocal(3);
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    // Use existing evaluated receiver and index for '[]=' call.
    invokeMethod(node, new Selector.indexSet());
    assembler.pop();
    applyVisitState();
  }

  void visitCompoundIndexSet(
      Send node,
      Node receiver,
      Node index,
      AssignmentOperator operator,
      Node rhs,
      _) {
    visitForValue(receiver);
    visitForValue(index);
    // Load already evaluated receiver and index for '[]' call.
    assembler.loadLocal(1);
    assembler.loadLocal(1);
    invokeMethod(node, new Selector.index());
    visitForValue(rhs);
    invokeMethod(node, getAssignmentSelector(operator));
    // Use existing evaluated receiver and index for '[]=' call.
    invokeMethod(node, new Selector.indexSet());
    applyVisitState();
  }

  void visitThisPropertyPrefix(
      Send node,
      IncDecOperator operator,
      Selector getterSelector,
      Selector setterSelector,
      _) {
    loadThis();
    doDynamicPrefix(node, operator, getterSelector, setterSelector);
    applyVisitState();
  }

  void visitThisPropertyPostfix(
      Send node,
      IncDecOperator operator,
      Selector getterSelector,
      Selector setterSelector,
      _) {
    // If visitState is for effect, we can ignore the return value, thus always
    // generate code for the simpler 'prefix' case.
    if (visitState == VisitState.Effect) {
      loadThis();
      doDynamicPrefix(node, operator, getterSelector, setterSelector);
      applyVisitState();
      return;
    }

    loadThis();
    invokeGetter(node, getterSelector);
    // For postfix, keep local, unmodified version, to 'return' after store.
    assembler.dup();
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    loadThis();
    assembler.loadLocal(1);
    invokeSetter(node, setterSelector);
    assembler.popMany(2);
    applyVisitState();
  }

  void visitDynamicPropertyPrefix(
      Send node,
      Node receiver,
      IncDecOperator operator,
      Selector getterSelector,
      Selector setterSelector,
      _) {
    visitForValue(receiver);
    doDynamicPrefix(node, operator, getterSelector, setterSelector);
    applyVisitState();
  }

  void visitDynamicPropertyPostfix(
      Send node,
      Node receiver,
      IncDecOperator operator,
      Selector getterSelector,
      Selector setterSelector,
      _) {
    // If visitState is for effect, we can ignore the return value, thus always
    // generate code for the simpler 'prefix' case.
    if (visitState == VisitState.Effect) {
      visitForValue(receiver);
      doDynamicPrefix(node, operator, getterSelector, setterSelector);
      applyVisitState();
      return;
    }

    int receiverSlot = assembler.stackSize;
    visitForValue(receiver);
    assembler.loadSlot(receiverSlot);
    invokeGetter(node, getterSelector);
    // For postfix, keep local, unmodified version, to 'return' after store.
    assembler.dup();
    assembler.loadLiteral(1);
    invokeMethod(node, getIncDecSelector(operator));
    assembler.loadSlot(receiverSlot);
    assembler.loadLocal(1);
    invokeSetter(node, setterSelector);
    assembler.popMany(2);
    assembler.storeLocal(1);
    // Pop receiver.
    assembler.pop();
    applyVisitState();
  }

  void visitThrow(Throw node) {
    visitForValue(node.expression);
    assembler.emitThrow();
    // TODO(ahe): It seems suboptimal that each throw is followed by a pop.
    applyVisitState();
  }

  void visitRethrow(Rethrow node) {
    if (tryBlockStack.isEmpty) {
      doCompileError();
    } else {
      TryBlock block = tryBlockStack.head;
      assembler.loadSlot(block.stackSize - 1);
      // TODO(ahe): It seems suboptimal that each throw is followed by a pop.
      assembler.emitThrow();
    }
    assembler.pop();
  }

  void callConstructor(Node node,
                       ConstructorElement constructor,
                       NodeList arguments,
                       CallStructure callStructure) {
    registerStaticInvocation(constructor);
    registerInstantiatedClass(constructor.enclosingClass);
    FletchFunctionBase function = context.backend.compileConstructor(
        constructor,
        registry);
    doStaticFunctionInvoke(node, function, arguments, callStructure);
  }

  void doConstConstructorInvoke(ConstantExpression constant) {
    var value = context.getConstantValue(constant);
    context.markConstantUsed(value);
    int constId = functionBuilder.allocateConstant(value);
    assembler.loadConst(constId);
  }

  void visitConstConstructorInvoke(
      NewExpression node,
      ConstructedConstantExpression constant,
      _) {
    // TODO(johnniwinther): We should not end up here with an bad constructor.
    if (!checkCompileError(elements[node.send])) {
      doConstConstructorInvoke(constant);
    }
    applyVisitState();
  }

  void visitBoolFromEnvironmentConstructorInvoke(
      NewExpression node,
      BoolFromEnvironmentConstantExpression constant,
      _) {
    doConstConstructorInvoke(constant);
    applyVisitState();
  }

  void visitIntFromEnvironmentConstructorInvoke(
      NewExpression node,
      IntFromEnvironmentConstantExpression constant,
      _) {
    doConstConstructorInvoke(constant);
    applyVisitState();
  }

  void visitStringFromEnvironmentConstructorInvoke(
      NewExpression node,
      StringFromEnvironmentConstantExpression constant,
      _) {
    doConstConstructorInvoke(constant);
    applyVisitState();
  }

  void errorNonConstantConstructorInvoke(
      NewExpression node,
      Element element,
      DartType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    doCompileError();
    applyVisitState();
  }

  void visitGenerativeConstructorInvoke(
      NewExpression node,
      ConstructorElement constructor,
      InterfaceType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    if (!checkCompileError(constructor)) {
      callConstructor(node, constructor.declaration, arguments, callStructure);
    }
    applyVisitState();
  }

  void visitFactoryConstructorInvoke(
      NewExpression node,
      ConstructorElement constructor,
      InterfaceType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    // If the constructor has an implementation, the implementation is the
    // factory we want to invoke. Redirect to
    // visitRedirectingFactoryConstructorInvoke, so we handle both cases of
    // either a factory or a redirecting factory.
    if (constructor.implementation != constructor) {
      ConstructorElement implementation = constructor.implementation;
      visitRedirectingFactoryConstructorInvoke(
          node,
          constructor,
          type,
          implementation.effectiveTarget,
          null,
          arguments,
          callStructure,
          null);
      return;
    }
    // TODO(ahe): Remove ".declaration" when issue 23135 is fixed.
    FletchFunctionBase function = requireFunction(constructor.declaration);
    doStaticFunctionInvoke(
        node, function, arguments, callStructure, factoryInvoke: true);
    applyVisitState();
  }

  void visitConstructorIncompatibleInvoke(
      NewExpression node,
      ConstructorElement constructor,
      InterfaceType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    if (!checkCompileError(constructor)) {
      doUnresolved(constructor.name);
    }
    applyVisitState();
  }

  void visitRedirectingGenerativeConstructorInvoke(
      NewExpression node,
      ConstructorElement constructor,
      InterfaceType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    visitGenerativeConstructorInvoke(
        node,
        constructor,
        type,
        arguments,
        callStructure,
        null);
 }

  void visitRedirectingFactoryConstructorInvoke(
      NewExpression node,
      ConstructorElement constructor,
      InterfaceType type,
      ConstructorElement effectiveTarget,
      InterfaceType effectiveTargetType,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    if (effectiveTarget.isGenerativeConstructor) {
      visitGenerativeConstructorInvoke(
          node,
          effectiveTarget,
          effectiveTargetType,
          arguments,
          callStructure,
          null);
    } else {
      visitFactoryConstructorInvoke(
          node,
          effectiveTarget,
          effectiveTargetType,
          arguments,
          callStructure,
          null);
    }
  }

  void visitUnresolvedConstructorInvoke(
      NewExpression node,
      Element constructor,
      DartType type,
      NodeList arguments,
      Selector selector,
      _) {
    if (!checkCompileError(constructor.enclosingClass)) {
      doUnresolved(node.send.toString());
    }
    applyVisitState();
  }

  void visitUnresolvedClassConstructorInvoke(
      NewExpression node,
      Element element,
      DartType type,
      NodeList arguments,
      Selector selector,
      _) {
    doUnresolved(node.send.toString());
    applyVisitState();
  }

  void visitAbstractClassConstructorInvoke(
      NewExpression node,
      ConstructorElement element,
      InterfaceType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    generateUnimplementedError(node, "Cannot allocate abstract class");
    applyVisitState();
  }

  void visitUnresolvedRedirectingFactoryConstructorInvoke(
      NewExpression node,
      ConstructorElement constructor,
      InterfaceType type,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    doUnresolved(node.send.toString());
    applyVisitState();
  }

  void doStaticGetterGet(Send node, FunctionElement getter) {
    if (getter == context.backend.fletchExternalNativeError) {
      assembler.loadSlot(0);
      return;
    }

    if (getter.isDeferredLoaderGetter) {
      generateUnimplementedError(node, "Deferred loading is not supported.");
      return;
    }

    FletchFunctionBase base = requireFunction(getter);
    int constId = functionBuilder.allocateConstantFromFunction(base.functionId);
    invokeStatic(node, constId, 0);
  }

  void handleStaticGetterGet(Send node, FunctionElement getter, _) {
    doStaticGetterGet(node, getter);
    applyVisitState();
  }

  void handleStaticGetterInvoke(
      Send node,
      FunctionElement getter,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    doStaticGetterGet(node, getter);
    for (Node argument in arguments) {
      visitForValue(argument);
    }
    invokeMethod(node, callStructure.callSelector);
    applyVisitState();
  }

  void handleStaticSetterSet(
      Send node,
      FunctionElement setter,
      Node rhs,
      _) {
    visitForValue(rhs);
    FletchFunctionBase base = requireFunction(setter);
    int constId = functionBuilder.allocateConstantFromFunction(base.functionId);
    invokeStatic(node, constId, 1);
    applyVisitState();
  }

  /**
   * Load the captured variables of [function], expressed in [info].
   *
   * If [function] captures itself, its field index is returned.
   */
  int pushCapturedVariables(FunctionElement function) {
    ClosureInfo info = closureEnvironment.closures[function];
    if (info == null) {
      // TODO(ahe): Do not throw here, instead fix bug in incremental compiler
      // (see test closure_capture).
      throw new IncrementalCompilationFailed(
          "Internal error: no closure info for $function");
    }
    int index = 0;
    if (info.isThisFree) {
      loadThis();
      index++;
    }
    int thisClosureIndex = -1;
    for (LocalElement element in info.free) {
      if (element == function) {
        // If we capture ourself, remember index and assign into closure after
        // allocation.
        assembler.loadLiteralNull();
        assert(thisClosureIndex == -1);
        thisClosureIndex = index;
      } else {
        // Load the raw value (the 'Box' when by reference).
        assembler.loadSlot(scope[element].slot);
      }
      index++;
    }
    return thisClosureIndex;
  }

  void visitFunctionExpression(FunctionExpression node) {
    FunctionElement function = elements[node];

    // If the closure captures itself, thisClosureIndex is the field-index in
    // the closure.
    int thisClosureIndex = pushCapturedVariables(function);
    bool needToStoreThisReference = thisClosureIndex >= 0;

    FletchClassBuilder classBuilder = context.backend.createClosureClass(
        function,
        closureEnvironment);
    int classConstant = functionBuilder.allocateConstantFromClass(
        classBuilder.classId);

    // NOTE: Currently we emit a storeField instruction in case a closure
    // captures itself. Changing fields makes it a mutable object.
    // We can therefore not allocate the object with `immutable = true`.
    // TODO(fletchc-team): Could we restrict this limitation.
    bool immutable = !closureEnvironment.closures[function].free.any(
        closureEnvironment.shouldBeBoxed) && !needToStoreThisReference;

    assembler.allocate(
        classConstant, classBuilder.fields, immutable: immutable);

    if (needToStoreThisReference) {
      assert (!immutable);
      assembler.dup();
      assembler.storeField(thisClosureIndex);
    }

    registerStaticInvocation(function);
    applyVisitState();
  }

  void visitExpression(Expression node) {
    generateUnimplementedError(
        node, "Missing visit of expression: ${node.runtimeType}");
    applyVisitState();
  }

  void visitStatement(Node node) {
    generateUnimplementedError(
        node, "Missing visit of statement: ${node.runtimeType}");
    assembler.pop();
  }

  void doStatements(NodeList statements) {
    List<Element> oldBlockLocals = blockLocals;
    blockLocals = <Element>[];
    int stackSize = assembler.stackSize;

    for (Node statement in statements) {
      statement.accept(this);
    }

    int stackSizeDifference = assembler.stackSize - stackSize;
    if (stackSizeDifference != blockLocals.length) {
      internalError(
          statements,
          "Unbalanced number of block locals and stack slots used by block.");
    }

    for (int i = blockLocals.length - 1; i >= 0; --i) {
      // TODO(ajohnsen): Pop range bytecode?
      assembler.pop();
      popVariableDeclaration(blockLocals[i]);
    }

    blockLocals = oldBlockLocals;
  }

  void visitBlock(Block node) {
    var breakLabel = new BytecodeLabel();
    jumpInfo[node] = new JumpInfo(assembler.stackSize, null, breakLabel);
    doStatements(node.statements);
    assembler.bind(breakLabel);
  }

  void visitEmptyStatement(EmptyStatement node) {
  }

  void visitExpressionStatement(ExpressionStatement node) {
    visitForEffect(node.expression);
  }

  // Called before 'return', as an option to replace the already evaluated
  // return value.
  // One example is setters.
  void optionalReplaceResultValue() { }

  void visitReturn(Return node) {
    Expression expression = node.expression;
    if (expression == null) {
      assembler.loadLiteralNull();
    } else {
      visitForValue(expression);
    }
    callFinallyBlocks(0, true);
    optionalReplaceResultValue();
    generateReturn(node);
  }

  // Find the JumpInfo matching the target of [node].
  JumpInfo getJumpTargetInfo(GotoStatement node) {
    JumpTarget target = elements.getTargetOf(node);
    if (target == null) {
      generateUnimplementedError(node, "'$node' not in loop");
      assembler.pop();
      return null;
    }
    Node statement = target.statement;
    JumpInfo info = jumpInfo[statement];
    if (info == null) {
      generateUnimplementedError(node, "'$node' has no target");
      assembler.pop();
    }
    return info;
  }

  void callFinallyBlocks(int targetStackSize, bool preserveTop) {
    int popCount = 0;
    for (var block in tryBlockStack) {
      // Break once all exited finally blocks are processed. Finally blocks
      // are ordered by stack size which coincides with scoping. Blocks with
      // stack sizes at least equal to target size are being exited.
      if (block.stackSize < targetStackSize) break;
      if (block.finallyLabel == null) continue;
      if (preserveTop) {
        // We reuse the exception slot as a temporary buffer for the top
        // element, which is located -1 relative to the block's stack size.
        assembler.storeSlot(block.stackSize - 1);
      }
      // TODO(ajohnsen): Don't pop, but let subroutineCall take a 'pop count'
      // argument, just like popAndBranch.
      while (assembler.stackSize > block.stackSize) {
        assembler.pop();
        popCount++;
      }
      assembler.subroutineCall(block.finallyLabel, block.finallyReturnLabel);
      if (preserveTop) {
        assembler.loadSlot(block.stackSize - 1);
        popCount--;
      }
    }
    // Reallign stack (should be removed, according to above TODO).
    for (int i = 0; i < popCount; i++) {
      // Note we dup, to make sure the top element is the return value.
      assembler.dup();
    }
  }

  void unbalancedBranch(GotoStatement node, bool isBreak) {
    JumpInfo info = getJumpTargetInfo(node);
    if (info == null) return;
    callFinallyBlocks(info.stackSize, false);
    BytecodeLabel label = isBreak ? info.breakLabel : info.continueLabel;
    int diff = assembler.stackSize - info.stackSize;
    assembler.popAndBranch(diff, label);
  }

  void visitBreakStatement(BreakStatement node) {
    var breakLabel = new BytecodeLabel();
    jumpInfo[node] = new JumpInfo(assembler.stackSize, null, breakLabel);
    unbalancedBranch(node, true);
    assembler.bind(breakLabel);
  }

  void visitContinueStatement(ContinueStatement node) {
    unbalancedBranch(node, false);
  }

  void visitIf(If node) {
    BytecodeLabel ifTrue = new BytecodeLabel();
    BytecodeLabel ifFalse = new BytecodeLabel();
    visitForTest(node.condition, ifTrue, ifFalse);
    assembler.bind(ifTrue);
    if (node.hasElsePart) {
      BytecodeLabel end = new BytecodeLabel();
      jumpInfo[node] = new JumpInfo(assembler.stackSize, null, end);
      doScopedStatement(node.thenPart);
      assembler.branch(end);
      assembler.bind(ifFalse);
      doScopedStatement(node.elsePart);
      assembler.bind(end);
    } else {
      jumpInfo[node] = new JumpInfo(assembler.stackSize, null, ifFalse);
      doScopedStatement(node.thenPart);
      assembler.bind(ifFalse);
    }
  }

  void visitFor(For node) {
    List<Element> oldBlockLocals = blockLocals;
    blockLocals = <Element>[];

    BytecodeLabel start = new BytecodeLabel();
    BytecodeLabel ifTrue = new BytecodeLabel();
    BytecodeLabel end = new BytecodeLabel();
    BytecodeLabel afterBody  = new BytecodeLabel();

    Node initializer = node.initializer;
    if (initializer != null) visitForEffect(initializer);

    jumpInfo[node] = new JumpInfo(assembler.stackSize, afterBody, end);

    assembler.bind(start);

    Expression condition = node.condition;
    if (condition != null) {
      visitForTest(condition, ifTrue, end);
      assembler.bind(ifTrue);
    }

    doScopedStatement(node.body);

    assembler.bind(afterBody);

    for (int i = blockLocals.length - 1; i >= 0; --i) {
      LocalElement local = blockLocals[i];
      // If the locals are captured by reference, load the current value and
      // store it in a new boxed.
      if (closureEnvironment.shouldBeBoxed(local)) {
        LocalValue value = scope[local];
        value.load(assembler);
        value.initialize(assembler);
        assembler.storeSlot(value.slot);
        assembler.pop();
      }
    }

    for (Node update in node.update) {
      visitForEffect(update);
    }
    assembler.branch(start);

    assembler.bind(end);

    for (int i = blockLocals.length - 1; i >= 0; --i) {
      assembler.pop();
      popVariableDeclaration(blockLocals[i]);
    }

    blockLocals = oldBlockLocals;
  }

  void visitSyncForIn(SyncForIn node) {
    visitForIn(node);
  }

  void visitForIn(ForIn node) {
    BytecodeLabel start = new BytecodeLabel();
    BytecodeLabel end = new BytecodeLabel();

    // Evalutate expression and iterator.
    visitForValue(node.expression);
    invokeGetter(node.expression, new Selector.getter('iterator', null));

    jumpInfo[node] = new JumpInfo(assembler.stackSize, start, end);

    assembler.bind(start);

    assembler.dup();
    invokeMethod(node, new Selector.call('moveNext', null, 0));
    assembler.branchIfFalse(end);

    bool isVariableDeclaration = node.declaredIdentifier.asSend() == null;
    Element element = elements[node];
    if (isVariableDeclaration) {
      // Create local value and load the current element to it.
      LocalValue value = createLocalValueFor(element);
      assembler.dup();
      invokeGetter(node, new Selector.getter('current', null));
      value.initialize(assembler);
      pushVariableDeclaration(value);
    } else {
      if (element == null || element.isInstanceMember) {
        loadThis();
        assembler.loadLocal(1);
        invokeGetter(node, new Selector.getter('current', null));
        Selector selector = elements.getSelector(node.declaredIdentifier);
        invokeSetter(node, selector);
      } else {
        assembler.dup();
        invokeGetter(node, new Selector.getter('current', null));
        if (element.isLocal) {
          scope[element].store(assembler);
        } else if (element.isField) {
          doStaticFieldSet(element);
        } else if (element.isErroneous) {
          doUnresolved(element.name);
          assembler.pop();
        } else {
          internalError(node, "Unhandled store in for-in");
        }
      }
      assembler.pop();
    }

    doScopedStatement(node.body);

    if (isVariableDeclaration) {
      // Pop the local again.
      assembler.pop();
      popVariableDeclaration(element);
    }

    assembler.branch(start);

    assembler.bind(end);

    // Pop iterator.
    assembler.pop();
  }

  void visitLabeledStatement(LabeledStatement node) {
    node.statement.accept(this);
  }

  // Visit the statement in a scope, where locals are popped when left.
  void doScopedStatement(Node statement) {
    Block block = statement.asBlock();
    if (block != null) {
      doStatements(block.statements);
    } else {
      doStatements(new NodeList.singleton(statement));
    }
  }

  void visitWhile(While node) {
    BytecodeLabel start = new BytecodeLabel();
    BytecodeLabel ifTrue = new BytecodeLabel();
    BytecodeLabel end = new BytecodeLabel();
    jumpInfo[node] = new JumpInfo(assembler.stackSize, start, end);
    assembler.bind(start);
    visitForTest(node.condition, ifTrue, end);
    assembler.bind(ifTrue);
    doScopedStatement(node.body);
    assembler.branch(start);
    assembler.bind(end);
  }

  void visitDoWhile(DoWhile node) {
    BytecodeLabel start = new BytecodeLabel();
    BytecodeLabel end = new BytecodeLabel();
    BytecodeLabel skipBody = new BytecodeLabel();
    jumpInfo[node] = new JumpInfo(assembler.stackSize, skipBody, end);
    assembler.bind(start);
    doScopedStatement(node.body);
    assembler.bind(skipBody);
    visitForTest(node.condition, start, end);
    assembler.bind(end);
  }

  LocalValue initializeLocal(LocalElement element, Expression initializer) {
    int slot = assembler.stackSize;
    if (initializer != null) {
      visitForValue(initializer);
    } else {
      assembler.loadLiteralNull();
    }
    LocalValue value = createLocalValueFor(element, slot);
    value.initialize(assembler);
    pushVariableDeclaration(value);
    blockLocals.add(element);
    return value;
  }

  void visitVariableDefinitions(VariableDefinitions node) {
    for (Node definition in node.definitions) {
      LocalVariableElement element = elements[definition];
      initializeLocal(element, element.initializer);
    }
  }

  void visitFunctionDeclaration(FunctionDeclaration node) {
    FunctionExpression function = node.function;
    initializeLocal(elements[function], function);
  }

  void visitSwitchStatement(SwitchStatement node) {
    BytecodeLabel end = new BytecodeLabel();

    visitForValue(node.expression);

    jumpInfo[node] = new JumpInfo(assembler.stackSize, null, end);

    // Install cross-case jump targets.
    for (SwitchCase switchCase in node.cases) {
      BytecodeLabel continueLabel = new BytecodeLabel();
      jumpInfo[switchCase] = new JumpInfo(
          assembler.stackSize,
          continueLabel,
          null);
    }

    for (SwitchCase switchCase in node.cases) {
      BytecodeLabel ifTrue = jumpInfo[switchCase].continueLabel;
      BytecodeLabel next = new BytecodeLabel();
      if (!switchCase.isDefaultCase) {
        for (Node labelOrCaseMatch in switchCase.labelsAndCases) {
          CaseMatch caseMatch = labelOrCaseMatch.asCaseMatch();
          if (caseMatch == null) continue;
          generateSwitchCaseMatch(caseMatch, ifTrue);
        }
        assembler.branch(next);
      }
      assembler.bind(ifTrue);
      doStatements(switchCase.statements);
      assembler.branch(end);
      assembler.bind(next);
    }

    assembler.bind(end);
    assembler.pop();
  }

  void doCatchBlock(CatchBlock node, int exceptionSlot, BytecodeLabel end) {
    BytecodeLabel wrongType = new BytecodeLabel();

    TypeAnnotation type = node.type;
    if (type != null) {
      assembler.loadSlot(exceptionSlot);
      callIsSelector(type, elements.getType(type), type);
      assembler.branchIfFalse(wrongType);
    }

    List<Element> locals = <Element>[];
    Node exception = node.exception;
    if (exception != null) {
      LocalVariableElement element = elements[exception];
      LocalValue value = createLocalValueFor(element);
      assembler.loadSlot(exceptionSlot);
      value.initialize(assembler);
      pushVariableDeclaration(value);
      locals.add(element);

      Node trace = node.trace;
      if (trace != null) {
        LocalVariableElement element = elements[trace];
        LocalValue value = createLocalValueFor(element);
        assembler.loadLiteralNull();
        value.initialize(assembler);
        pushVariableDeclaration(value);
        // TODO(ajohnsen): Set trace.
        locals.add(element);
      }
    }

    node.block.accept(this);

    assembler.popMany(locals.length);
    for (Element e in locals) {
      popVariableDeclaration(e);
    }

    assembler.branch(end);

    assembler.bind(wrongType);
  }

  void visitTryStatement(TryStatement node) {
    BytecodeLabel end = new BytecodeLabel();
    BytecodeLabel finallyLabel = new BytecodeLabel();
    BytecodeLabel finallyReturnLabel = new BytecodeLabel();

    Block finallyBlock = node.finallyBlock;
    bool hasFinally = finallyBlock != null;

    // Reserve slot for exception.
    int exceptionSlot = assembler.stackSize;
    assembler.loadLiteralNull();

    jumpInfo[node] = new JumpInfo(assembler.stackSize, null, end);

    int startBytecodeSize = assembler.byteSize;

    tryBlockStack = tryBlockStack.prepend(
        new TryBlock(
            assembler.stackSize,
            hasFinally ? finallyLabel : null,
            hasFinally ? finallyReturnLabel: null));

    node.tryBlock.accept(this);

    // Go to end if no exceptions was thrown.
    assembler.branch(end);
    int endBytecodeSize = assembler.byteSize;

    // Add catch-frame to the assembler.
    assembler.addCatchFrameRange(startBytecodeSize, endBytecodeSize);

    for (Node catchBlock in node.catchBlocks) {
      doCatchBlock(catchBlock, exceptionSlot, end);
    }

    tryBlockStack = tryBlockStack.tail;

    if (hasFinally) {
      if (!node.catchBlocks.isEmpty) {
        assembler.addCatchFrameRange(endBytecodeSize, assembler.byteSize);
      }
      // Catch exception from catch blocks.
      assembler.subroutineCall(finallyLabel, finallyReturnLabel);
    }

    // The exception was not cought. Rethrow.
    assembler.emitThrow();

    assembler.bind(end);

    if (hasFinally) {
      BytecodeLabel done = new BytecodeLabel();
      assembler.subroutineCall(finallyLabel, finallyReturnLabel);
      assembler.branch(done);

      assembler.bind(finallyLabel);
      assembler.applyStackSizeFix(1);
      finallyBlock.accept(this);
      assembler.subroutineReturn(finallyReturnLabel);

      assembler.bind(done);
    }

    // Pop exception slot.
    assembler.pop();
  }

  void doUnresolved(String name) {
    var constString = context.backend.constantSystem.createString(
        new DartString.literal(name));
    context.markConstantUsed(constString);
    assembler.loadConst(functionBuilder.allocateConstant(constString));
    FunctionElement function = context.backend.fletchUnresolved;
    FletchFunctionBase base = requireFunction(function);
    int constId = functionBuilder.allocateConstantFromFunction(base.functionId);
    assembler.invokeStatic(constId, 1);
  }

  bool checkCompileError(Element element) {
    if (context.compiler.elementsWithCompileTimeErrors.contains(element)) {
      doCompileError();
      return true;
    }
    return false;
  }

  void doCompileError() {
    FunctionElement function = context.backend.fletchCompileError;
    FletchFunctionBase base = requireFunction(function);
    int constId = functionBuilder.allocateConstantFromFunction(base.functionId);
    assembler.invokeStatic(constId, 0);
  }

  void visitUnresolvedInvoke(
      Send node,
      Element element,
      Node arguments,
      Selector selector,
      _) {
    if (!checkCompileError(element)) {
      doUnresolved(node.selector.toString());
    }
    applyVisitState();
  }

  void visitUnresolvedGet(
      Send node,
      Element element,
      _) {
    doUnresolved(node.selector.toString());
    applyVisitState();
  }

  void visitUnresolvedSet(
      Send node,
      Element element,
      Node rhs,
      _) {
    doUnresolved(node.selector.toString());
    applyVisitState();
  }

  void handleStaticFunctionIncompatibleInvoke(
      Send node,
      MethodElement function,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    if (!checkCompileError(function)) {
      doUnresolved(function.name);
    }
    applyVisitState();
  }

  void internalError(Spannable spannable, String reason) {
    context.compiler.internalError(spannable, reason);
  }

  void generateUnimplementedError(Spannable spannable, String reason) {
    context.backend.generateUnimplementedError(
        spannable,
        reason,
        functionBuilder);
  }

  String toString() => "FunctionCompiler(${element.name})";

  void handleFinalStaticFieldSet(
      SendSet node,
      FieldElement field,
      Node rhs,
      _) {
    generateUnimplementedError(
        node, "[handleFinalStaticFieldSet] isn't implemented.");
    applyVisitState();
  }

  void handleImmutableLocalSet(
      SendSet node,
      LocalElement element,
      Node rhs,
      _) {
    generateUnimplementedError(
        node, "[handleImmutableLocalSet] isn't implemented.");
    applyVisitState();
  }

  void handleStaticSetterGet(
      Send node,
      FunctionElement setter,
      _) {
    generateUnimplementedError(
        node, "[handleStaticSetterGet] isn't implemented.");
    applyVisitState();
  }

  void handleStaticSetterInvoke(
      Send node,
      FunctionElement setter,
      NodeList arguments,
      CallStructure callStructure,
      _) {
    generateUnimplementedError(
        node, "[handleStaticSetterInvoke] isn't implemented.");
    applyVisitState();
  }

  void handleStaticGetterSet(
      Send node,
      FunctionElement getter,
      Node rhs,
      _) {
    generateUnimplementedError(
        node, "[handleStaticGetterSet] isn't implemented.");
    applyVisitState();
  }

  void handleStaticFunctionSet(
      SendSet node,
      MethodElement function,
      Node rhs,
      _) {
    generateUnimplementedError(
        node, "[handleStaticFunctionSet] isn't implemented.");
    applyVisitState();
  }

  void previsitDeferredAccess(Send node, PrefixElement prefix, _) {
    // We don't support deferred access, so nothing to do for now.
  }

  void bulkHandleNode(Node node, String msg, _) {
    generateUnimplementedError(node, msg.replaceAll('#', node.toString()));
    applyVisitState();
  }

  void visitNode(Node node) {
    internalError(node, "[visitNode] isn't implemented.");
  }

  void apply(Node node, _) {
    internalError(node, "[apply] isn't implemented.");
  }

  void applyInitializers(FunctionExpression initializers, _) {
    internalError(initializers, "[applyInitializers] isn't implemented.");
  }

  void applyParameters(NodeList parameters, _) {
    internalError(parameters, "[applyParameters] isn't implemented.");
  }
}
