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

package org.mirah.typer.simple

import java.util.*
import org.mirah.typer.*
import mirah.lang.ast.NodeScanner
import mirah.lang.ast.Node
import mirah.lang.ast.Position
import mirah.impl.MirahParser
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.FileInputStream
import java.io.PrintStream

# A simple Type implementation for SimpleTypes.
class SimpleType < SpecialType
  def initialize(name:String, meta=false, array=false)
    super(name)
    @meta = meta
    @array = array
  end

  def widen(other)
    return self if other.matchesAnything
    return ErrorType.new([ErrorMessage.new("Incompatible types")]) unless equals(other)
    self
  end
  def assignableFrom(other)
    matchesAnything || other.matchesAnything || equals(other)
  end
  def isMeta
    @meta
  end
  def isArray
    @array
  end
  def toString
    "<#{isMeta ? 'Meta' : ''}Type #{name}#{isArray ? '[]' : ''}>"
  end
  def equals(other)
    return false if other.nil?
    toString.equals(other.toString)
  end
  def hashCode
    toString.hashCode
  end
end

