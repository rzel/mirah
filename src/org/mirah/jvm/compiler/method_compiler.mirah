# Copyright (c) 2012 The Mirah project authors. All Rights Reserved.
# All contributing project authors may be found in the NOTICE file.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package org.mirah.jvm.compiler

import java.util.LinkedList
import java.util.logging.Logger
import mirah.lang.ast.*
import org.mirah.jvm.types.JVMType
import org.jruby.org.objectweb.asm.*
import org.jruby.org.objectweb.asm.Type as AsmType
import org.jruby.org.objectweb.asm.commons.GeneratorAdapter


import java.util.List

class MethodCompiler < BaseCompiler
  def self.initialize:void
    @@log = Logger.getLogger(MethodCompiler.class.getName)
  end
  def initialize(context:Context, klass:JVMType, flags:int, name:String)
    super(context)
    @flags = flags
    @name = name
    @locals = {}
    @args = {}
    @klass = klass
  end
  
  def isVoid
    @descriptor.getDescriptor.endsWith(")V")
  end
  
  def isStatic
    (@flags & Opcodes.ACC_STATIC) != 0
  end
  
  def bytecode
    @builder
  end
  
  def compile(cv:ClassVisitor, mdef:MethodDefinition):void
    @builder = createBuilder(cv, mdef)
    context[AnnotationCompiler].compile(mdef.annotations, @builder)
    isExpression = isVoid() ? nil : Boolean.TRUE
    if (@flags & Opcodes.ACC_ABSTRACT) == 0
      visit(mdef.body, isExpression)
      body_position = if mdef.body_size > 0
        mdef.body(mdef.body_size - 1).position
      else
        mdef.body.position
      end
      returnValue(mdef)
    end
    @builder.endMethod
  end

  def compile(node:Node)
    visit(node, Boolean.TRUE)
  end

  def collectArgNames(mdef:MethodDefinition):void
    i = 0
    args = mdef.arguments
    args.required_size.times do |a|
      @args[args.required(a).name.identifier] = Integer.valueOf(i)
      i += 1
    end
    args.optional_size.times do |a|
      @args[args.optional(a).name.identifier] = Integer.valueOf(i)
      i += 1
    end
    if args.rest
      @args[args.rest.name.identifier] = Integer.valueOf(i)
      i += 1
    end
    args.required2_size.times do |a|
      @args[args.required2(a).name.identifier] = Integer.valueOf(i)
      i += 1
    end
  end

  def createBuilder(cv:ClassVisitor, mdef:MethodDefinition)
    type = getInferredType(mdef)
    @returnType = JVMType(type.returnType)
    if @name.endsWith("init>")
      @returnType = JVMType(typer.type_system.getVoidType.resolve)
    end
    @descriptor = methodDescriptor(@name, @returnType, type.parameterTypes)
    @selfType = JVMType(getScope(mdef).selfType.resolve)
    superclass = @selfType.superclass
    @superclass = superclass || JVMType(
        typer.type_system.get(nil, TypeRefImpl.new("java.lang.Object", false, false, nil)).resolve)
    collectArgNames(mdef)
    Bytecode.new(@flags, @descriptor, cv)
  end
  
  def recordPosition(position:Position)
    @builder.recordPosition(position)
  end
  
  def defaultValue(type:JVMType)
    if type.isPrimitive
      if 'long'.equals(type.name)
        @builder.push(long(0))
      elsif 'double'.equals(type.name)
        @builder.push(double(0))
      elsif 'float'.equals(type.name)
        @builder.push(float(0))
      else
        @builder.push(0)
      end
    else
      @builder.push(String(nil))
    end
  end
  
  def visitFixnum(node, expression)
    if expression
      isLong = "long".equals(getInferredType(node).name)
      recordPosition(node.position)
      if isLong
        @builder.push(node.value)
      else
        @builder.push(int(node.value))
      end
    end
  end
  def visitFloat(node, expression)
    if expression
      isFloat = "float".equals(getInferredType(node).name)
      recordPosition(node.position)
      if isFloat
        @builder.push(float(node.value))
      else
        @builder.push(node.value)
      end
    end
  end
  def visitBoolean(node, expression)
    if expression
      recordPosition(node.position)
      @builder.push(node.value ? 1 : 0)
    end
  end
  def visitSimpleString(node, expression)
    if expression
      recordPosition(node.position)
      @builder.push(node.value)
    end
  end
  def visitNull(node, expression)
    value = String(nil)
    if expression
      recordPosition(node.position)
      @builder.push(value)
    end
  end
  
  def visitSuper(node, expression)
    @builder.loadThis
    paramTypes = LinkedList.new
    node.parameters_size.times do |i|
      param = node.parameters(i)
      compile(param)
      paramTypes.add(getInferredType(param))
    end
    recordPosition(node.position)
    method = @superclass.getMethod(@name, paramTypes)
    # This is a poorly named method, really it's invokeSpecial
    @builder.invokeConstructor(@superclass.getAsmType, methodDescriptor(method))
    if expression && isVoid
      @builder.loadThis
    elsif expression.nil? && !isVoid
      @builder.pop(@returnType)
    end
  end
  
  def visitLocalAccess(local, expression)
    if expression
      recordPosition(local.position)
      name = local.name.identifier
      index = @locals[name]
      if index
        @builder.loadLocal(Integer(index).intValue)
      else
        index = @args[name]
        @builder.loadArg(Integer(index).intValue)
      end
    end
  end

  def visitLocalAssignment(local, expression)
    visit(local.value, Boolean.TRUE)
    @builder.dup if expression
    name = local.name.identifier
    index = @locals[name]
    argIndex = @args[name]
    if index.nil? && argIndex.nil?
      # TODO put variable name into debug info
      type = getInferredType(local).getAsmType
      index = Integer.valueOf(@builder.newLocal(type))
      @locals[name] = index
    end
    recordPosition(local.position)
    if index
      @builder.storeLocal(Integer(index).intValue)
    else
      @builder.storeArg(Integer(argIndex).intValue)
    end
  end
  
  def visitFunctionalCall(call, expression)
    compiler = CallCompiler.new(self, @builder, call.position, call.target, call.name.identifier, call.parameters)
    compiler.compile(expression != nil)
  end
  
  def visitCall(call, expression)
    compiler = CallCompiler.new(self, @builder, call.position, call.target, call.name.identifier, call.parameters)
    compiler.compile(expression != nil)
  end
  
  def compileBody(node:NodeList, expression:Object, type:JVMType)
    if node.size == 0
      if expression
        defaultValue(type)
      else
        @builder.visitInsn(Opcodes.NOP)
      end
    else
      visitNodeList(node, expression)
    end
  end
  
  def visitIf(node, expression)
    elseLabel = @builder.newLabel
    endifLabel = @builder.newLabel
    compiler = ConditionCompiler.new(self, @builder)
    type = getInferredType(node)
    
    need_then = !expression.nil? || node.body_size > 0
    need_else = !expression.nil? || node.elseBody_size > 0

    if need_then
      compiler.negate
      compiler.compile(node.condition, elseLabel)
      compileBody(node.body, expression, type)
      @builder.goTo(endifLabel)
    else
      compiler.compile(node.condition, endifLabel)
    end
    
    @builder.mark(elseLabel)
    if need_else
      compileBody(node.elseBody, expression, type)
    end
    @builder.mark(endifLabel)
  end
  
  def visitImplicitNil(node, expression)
    if expression
      defaultValue(getInferredType(node))
    end
  end
  
  def visitReturn(node, expression)
    compile(node.value) unless isVoid
    @builder.returnValue
  end
  
  def visitCast(node, expression)
    compile(node.value)
    from = getInferredType(node.value)
    to = getInferredType(node)
    if from.isPrimitive
      @builder.cast(from.getAsmType, to.getAsmType)
    else
      @builder.checkCast(to.getAsmType)
    end
    @builder.pop(to) unless expression
  end
  
  def visitFieldAccess(node, expression)
    klass = @selfType.getAsmType
    name = node.name.identifier
    type = getInferredType(node)
    isStatic = node.isStatic || self.isStatic
    if isStatic
      recordPosition(node.position)
      @builder.getStatic(klass, name, type.getAsmType)
    else
      @builder.loadThis
      recordPosition(node.position)
      @builder.getField(klass, name, type.getAsmType)
    end
    unless expression
      @builder.pop(type)
    end
  end
  
  def visitFieldAssign(node, expression)
    klass = @selfType.getAsmType
    name = node.name.identifier
    isStatic = node.isStatic || self.isStatic
    type = @klass.getDeclaredField(node.name.identifier).returnType
    @builder.loadThis unless isStatic
    compile(node.value)
    valueType = getInferredType(node.value)
    if expression
      if isStatic
        @builder.dup(valueType)
      else
        @builder.dupX1(valueType)
      end
    end
    @builder.convertValue(valueType, type)
    
    recordPosition(node.position)
    if isStatic
      @builder.putStatic(klass, name, type.getAsmType)
    else
      @builder.putField(klass, name, type.getAsmType)
    end
  end
  
  def visitEmptyArray(node, expression)
    compile(node.size)
    recordPosition(node.position)
    type = getInferredType(node).getComponentType
    @builder.newArray(type.getAsmType)
    @builder.pop unless expression
  end
  
  def visitAttrAssign(node, expression)
    compiler = CallCompiler.new(
        self, @builder, node.position, node.target,
        "#{node.name.identifier}_set", [node.value])
    compiler.compile(expression != nil)
  end
  
  def visitStringConcat(node, expression)
    visit(node.strings, expression)
  end
  
  def visitStringPieceList(node, expression)
    if node.size == 0
      if expression
        recordPosition(node.position)
        @builder.push("")
      end
    elsif node.size == 1 && node.get(0).kind_of?(SimpleString)
      visit(node.get(0), expression)
    else
      compiler = StringCompiler.new(self)
      compiler.compile(node, expression != nil)
    end
  end
  
  def visitRegex(node, expression)
    # TODO regex flags
    compile(node.strings)
    recordPosition(node.position)
    pattern = findType("java.util.regex.Pattern")
    @builder.invokeStatic(pattern.getAsmType, methodDescriptor("compile", pattern, [findType("java.lang.String")]))
    @builder.pop unless expression
  end
  
  def visitNot(node, expression)
    visit(node.value, expression)
    if expression
      recordPosition(node.position)
      done = @builder.newLabel
      elseLabel = @builder.newLabel
      type = getInferredType(node.value)
      if type.isPrimitive
        @builder.ifZCmp(GeneratorAdapter.EQ, elseLabel)
      else
        @builder.ifNull(elseLabel)
      end
      @builder.push(0)
      @builder.goTo(done)
      @builder.mark(elseLabel)
      @builder.push(1)
      @builder.mark(done)
    end
  end
  
  def returnValue(mdef:MethodDefinition)
    body = mdef.body
    type = getInferredType(body)
    unless isVoid || @returnType.assignableFrom(type)
      # TODO this error should be caught by the typer
      body_position = if body.size > 0
        body.get(body.size - 1).position
      else
        body.position
      end
      reportError("Invalid return type #{type.name}, expected #{@returnType.name}", body_position)
    end
    @builder.returnValue
  end
  
  def visitSelf(node, expression)
    if expression
      recordPosition(node.position)
      @builder.loadThis
    end
  end

  def visitImplicitSelf(node, expression)
    if expression
      recordPosition(node.position)
      @builder.loadThis
    end
  end
  
  def visitLoop(node, expression)
    old_loop = @loop
    @loop = LoopCompiler.new(@builder)
    
    visit(node.init, nil)
    
    predicate = ConditionCompiler.new(self, @builder)
    
    preLabel = @builder.newLabel
    unless node.skipFirstCheck
      @builder.mark(@loop.getNext) unless node.post_size > 0
      # Jump out of the loop if the condition is false
      predicate.negate unless node.negative
      predicate.compile(node.condition, @loop.getBreak)
    end
      
    @builder.mark(preLabel)
    visit(node.pre, nil)
    
    @builder.mark(@loop.getRedo)
    visit(node.body, nil) if node.body
    
    if node.skipFirstCheck || node.post_size > 0
      @builder.mark(@loop.getNext)
      visit(node.post, nil)
      # Loop if the condition is true
      predicate.negate if node.negative
      predicate.compile(node.condition, preLabel)
    else
      @builder.goTo(@loop.getNext)
    end
    @builder.mark(@loop.getBreak)

    # loops always evaluate to null
    @builder.pushNil if expression
  ensure
    @loop = old_loop
  end
  
  def visitBreak(node, expression)
    if @loop
      @builder.goTo(@loop.getBreak)
    else
      reportError("Break outside of loop", node.position)
    end
  end
  
  def visitRedo(node, expression)
    if @loop
      @builder.goTo(@loop.getRedo)
    else
      reportError("Redo outside of loop", node.position)
    end
  end
  
  def visitNext(node, expression)
    if @loop
      @builder.goTo(@loop.getNext)
    else
      reportError("Next outside of loop", node.position)
    end
  end
end