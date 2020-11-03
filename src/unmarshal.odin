package main

import "core:encoding/json"
import "core:strings"
import "core:runtime"
import "core:mem"
import "core:fmt"

//Note(Daniel, investigate if you can use some sort of attribute not to be forced to have the same variable name as the json name)

unmarshal :: proc(json_value: json.Value, v: any, allocator := context.allocator) -> json.Marshal_Error  {

	using runtime;

	if v == nil {
		return .None;
	}

	type_info := type_info_base(type_info_of(v.id));

	#partial
	switch j in json_value.value {
	case json.Object:
		#partial switch variant in type_info.variant {
		case Type_Info_Struct:
			for field, i in variant.names {
				a := any{rawptr(uintptr(v.data) + uintptr(variant.offsets[i])), variant.types[i].id};
				if ret := unmarshal(j[field], a, allocator); ret != .None {
					return ret;
				}
			}
		}
	case json.Array:
		#partial switch variant in type_info.variant {
		case Type_Info_Dynamic_Array:
			array := (^mem.Raw_Dynamic_Array)(v.data);
			if array.data == nil {
				array.data      = mem.alloc(len(j)*variant.elem_size, variant.elem.align, allocator);
                array.len       = len(j);
                array.cap       = len(j);
                array.allocator = allocator;
			}
			else {
				return .Invalid_Data; 
			}

			for i in 0..<array.len {
                a := any{rawptr(uintptr(array.data) + uintptr(variant.elem_size * i)), variant.elem.id};

                if ret := unmarshal(j[i], a, allocator); ret != .None {
					return ret;
				}
            }

		case:
			return .Unsupported_Type;
		}
	case json.String:
		#partial switch variant in type_info.variant {
        case Type_Info_String:
            str := (^string)(v.data);
            str^ = strings.clone(j, allocator);
		
		case Type_Info_Enum:
			for name, i in variant.names {

				lower_name := strings.to_lower(name, allocator);
				lower_j := strings.to_lower(string(j), allocator);
				 
                if lower_name == lower_j {
					mem.copy(v.data, &variant.values[i], size_of(variant.base));
                }

				delete(lower_name, allocator);
				delete(lower_j, allocator);
            }
		}
	case json.Integer:
		#partial switch variant in &type_info.variant {
        case Type_Info_Integer:
            switch type_info.size {
            case 8:
                tmp := i64(j);
                mem.copy(v.data, &tmp, type_info.size);

            case 4:
                tmp := i32(j);
                mem.copy(v.data, &tmp, type_info.size);

            case 2:
                tmp := i16(j);
                mem.copy(v.data, &tmp, type_info.size);

            case 1:
                tmp := i8(j);
                mem.copy(v.data, &tmp, type_info.size);
            case: 
				return .Invalid_Data;
            }
		case Type_Info_Union:
			tag_ptr := uintptr(v.data) + variant.tag_offset;
		}
	case json.Float:
        if _, ok := type_info.variant.(Type_Info_Float); ok {
            switch type_info.size {
            case 8:
                tmp := f64(j);
                mem.copy(v.data, &tmp, type_info.size);
            case 4:
                tmp := f32(j);
                mem.copy(v.data, &tmp, type_info.size);
            case: 
				return .Invalid_Data;
            }

        }
	case json.Null:
    case json.Boolean :
        if _, ok := type_info.variant.(Type_Info_Boolean); ok {
            tmp := bool(j);
            mem.copy(v.data, &tmp, type_info.size);
        }
	case:
		return .Unsupported_Type;
	}

	return .None;
}

