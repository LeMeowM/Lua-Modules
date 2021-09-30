---
-- @Liquipedia
-- wiki=commons
-- page=Module:TypeUtil
--
-- Please see https://github.com/Liquipedia/Lua-Modules to contribute
--

local Array = require('Module:Array')
local Table = require('Module:Table')

local TypeUtil = {}

TypeUtil.literal = function(value)
	return {op = 'literal', value = value}
end

TypeUtil.optional = function(typeSpec)
	if type(typeSpec) == 'string' then
		return require('Module:StringUtils').endsWith(typeSpec, '?')
			and typeSpec
			or typeSpec .. '?'
	else
		return {op = 'optional', type = typeSpec}
	end
end

TypeUtil.union = function(...)
	return {op = 'union', types = Array.copy(...)}
end

TypeUtil.literalUnion = function(...)
	return TypeUtil.union(unpack(
		Array.map(..., TypeUtil.literal)
	))
end

TypeUtil.extendLiteralUnion = function(union, ...)
	return {
		op = 'union',
		types = Array.extend(union.types, Array.map(..., TypeUtil.literal)),
	}
end

--[[
Non-strict structural type for tables. Tables may have additional entries not
in the structural type.
]]
TypeUtil.struct = function(struct)
	return {op = 'struct', struct = struct}
end

--[[
Adds additional fields to a structural type.
]]
TypeUtil.extendStruct = function(type, struct)
	return {op = 'struct', struct = Table.merge(type.struct, struct)}
end

--[[
Table type.
]]
TypeUtil.table = function(keyType, valueType)
	if keyType or valueType then
		return {op = 'table', keyType = keyType or 'any', valueType = valueType or 'any'}
	else
		return 'table'
	end
end

--[[
Type for tables that are arrays. Not strict - arrays may have additional fields
besides numeric indexes, and may have gaps in indexes.
]]
TypeUtil.array = function(elemType)
	if elemType then
		return {op = 'array', elemType = elemType}
	else
		return 'array'
	end
end

--[[
Whether a value satisfies a type, ignoring table contents. Table contents are
checked in TypeUtil.getTypeErrors.
]]
TypeUtil.valueIsTypeNoTable = function(value, typeSpec)
	if type(typeSpec) == 'string' then
		if typeSpec == 'string'
			or typeSpec == 'number'
			or typeSpec == 'boolean'
			or typeSpec == 'function'
			or typeSpec == 'table'
			or typeSpec == 'nil' then
			return type(value) == typeSpec
		elseif require('Module:StringUtils').endsWith(typeSpec, '?') then
			return value == nil or TypeUtil.valueIsTypeNoTable(value, typeSpec:sub(1, -2))
		elseif typeSpec == 'any' then
			return true
		elseif typeSpec == 'never' then
			return false
		end
	elseif type(typeSpec) == 'table' then
		if typeSpec.op == 'literal' then
			return value == typeSpec.value
		elseif typeSpec.op == 'optional' then
			return value == nil or TypeUtil.valueIsTypeNoTable(value, typeSpec.type)
		elseif typeSpec.op == 'union' then
			return Array.any(
				typeSpec.types,
				function(typeSpec_) return TypeUtil.valueIsTypeNoTable(value, typeSpec_) end
			)
		elseif typeSpec.op == 'table' or typeSpec.op == 'struct' or typeSpec.op == 'array' then
			return type(value) == 'table'
		end
	end
	return true
end

TypeUtil._getTypeErrors = function(value, typeSpec, nameParts, options, getTypeErrors)
	if not TypeUtil.valueIsTypeNoTable(value, typeSpec) then
		return {
			{value = value, type = typeSpec, where = nameParts}
		}
	end

	if type(typeSpec) == 'table' and options.recurseOnTable then
		if typeSpec.op == 'optional' then
			return value == nil
				and {}
				or getTypeErrors(value, typeSpec.type)

		elseif typeSpec.op == 'union' then
			local errors = {}
			for _, option in ipairs(typeSpec.types) do
				errors = getTypeErrors(value, option)
				if #errors == 0 then break end
			end
			return errors

		elseif typeSpec.op == 'table' then
			for tableKey, tableValue in pairs(value) do
				local errors = Array.extendWith(
					getTypeErrors(tableKey, typeSpec.keyType, {type = 'tableKey', key = tableKey}),
					getTypeErrors(tableValue, typeSpec.valueType, {type = 'tableValue', key = tableKey})
				)
				if #errors > 0 then return errors end
			end
			return {}

		elseif typeSpec.op == 'struct' then
			local errors = {}
			for fieldName, fieldType in pairs(typeSpec.struct) do
				Array.extendWith(
					errors,
					getTypeErrors(value[fieldName], fieldType, {type = 'tableValue', key = fieldName})
				)
			end
			return errors

		elseif typeSpec.op == 'array' then
			for ix, elem in ipairs(value) do
				local errors = getTypeErrors(elem, typeSpec.elemType, {type = 'tableValue', key = ix})
				if #errors > 0 then return errors end
			end
			return {}

		end
	end

	return {}
end

TypeUtil.getTypeErrors = function(value, typeSpec, options_)
	options_ = options_ or {}
	local options = {
		maxDepth = options_.maxDepth or math.huge,
		name = options_.name,
	}
	-- luacheck: ignore
	local function getTypeErrors(value, typeSpec, nameParts, depth)
		return TypeUtil._getTypeErrors(
			value,
			typeSpec,
			nameParts,
			{recurseOnTable = depth < options.maxDepth},
			function(value, typeSpec, namePart)
				return getTypeErrors(value, typeSpec, Array.append(nameParts, namePart), depth + 1)
			end
		)
	end

	local nameParts = {
		options.name and {type = 'base', name = options.name} or nil
	}
	return getTypeErrors(value, typeSpec, nameParts, 0)
end

-- Checks, at runtime, whether a value satisfies a type.
TypeUtil.checkValue = function(value, typeSpec, options)
	return Array.map(
		TypeUtil.getTypeErrors(value, typeSpec, options),
		TypeUtil.typeErrorToString
	)
end

-- Checks, at runtime, whether a value satisfies a type, and throws if not.
TypeUtil.assertValue = function(value, typeSpec, options)
	local errors = TypeUtil.checkValue(value, typeSpec, options)
	if #errors > 0 then
		error(table.concat(errors, '\n'))
	end
end

TypeUtil.typeErrorToString = function(typeError)
	local whereDescription = TypeUtil.whereToDescription(typeError.where)
	return 'Unexpected value'
		.. (whereDescription and ' in ' .. whereDescription or '')
		.. '. Found: '
		.. tostring(typeError.value)
		.. ' Expected: value of type '
		.. TypeUtil.typeToDescription(typeError.type)
end

TypeUtil.whereToDescription = function(nameParts)
	local s
	for _, namePart in ipairs(nameParts) do
		if namePart.type == 'base' then
			s = namePart.name
		elseif namePart.type == 'tableKey' then
			s = 'key ' .. tostring(namePart.key) .. (s and ' of ' .. s or '')
		elseif namePart.type == 'tableValue' then
			if s and type(namePart.key) == 'string' and namePart.key:match('^%w+$') then
				s = s .. '.' .. tostring(namePart.key)
			elseif s then
				s = s .. '[' .. TypeUtil.reprValue(namePart.key) .. ']'
			else
				s = 'table entry ' .. TypeUtil.reprValue(namePart.key)
			end
		end
	end
	return s
end

TypeUtil.reprValue = function(value)
	if type(value) == 'string' then
		return '\'' .. TypeUtil.escapeSingleQuote(value) .. '\''
	else
		return tostring(value)
	end
end

TypeUtil.typeToDescription = function(typeSpec)
	if type(typeSpec) == 'string' then
		return typeSpec
	elseif type(typeSpec) == 'table' then
		if typeSpec.op == 'literal' then
			return type(typeSpec.value) == 'string'
				and TypeUtil.reprValue(typeSpec.value)
				or tostring(typeSpec.value)
		elseif typeSpec.op == 'optional' then
			return 'optional ' .. TypeUtil.typeToDescription(typeSpec.type)
		elseif typeSpec.op == 'union' then
			return table.concat(Array.map(typeSpec.types, TypeUtil.typeToDescription), ' or ')
		elseif typeSpec.op == 'table' then
			return 'table'
		elseif typeSpec.op == 'struct' then
			return 'structural table'
		elseif typeSpec.op == 'array' then
			return 'array table'
		end
	end
end

TypeUtil.escapeSingleQuote = function(str)
	return str:gsub('\'', '\\\'')
end

-- checks if the entered value is numeric
function TypeUtil.isNumeric(val)
	return tonumber(val) ~= nil
end

return TypeUtil
