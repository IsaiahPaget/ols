package server

import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:path"
import "core:mem"
import "core:strconv"
import "core:path/filepath"
import "core:sort"
import "core:slice"

import "shared:common"
import "shared:index"

get_completion_list :: proc(document: ^Document, position: common.Position) -> (CompletionList, bool) {

    list: CompletionList;

    ast_context := make_ast_context(document.ast, document.imports, document.package_name);

    position_context, ok := get_document_position_context(document, position, .Completion);

    get_globals(document.ast, &ast_context);

    ast_context.current_package = ast_context.document_package;

    if position_context.function != nil {
        get_locals(document.ast, position_context.function, &ast_context, &position_context);
    }

    if position_context.comp_lit != nil && is_lhs_comp_lit(&position_context) {
        get_comp_lit_completion(&ast_context, &position_context, &list);
    }

    else if position_context.selector != nil {
        get_selector_completion(&ast_context, &position_context, &list);
    }

    else if position_context.implicit {
        get_implicit_completion(&ast_context, &position_context, &list);
    }

    else {
        get_identifier_completion(&ast_context, &position_context, &list);
    }

    return list, true;
}

is_lhs_comp_lit :: proc(position_context: ^DocumentPositionContext) -> bool {

    if len(position_context.comp_lit.elems) == 0 {
        return true;
    }

    for elem in position_context.comp_lit.elems {

        if position_in_node(elem, position_context.position) {

            log.infof("in %v", elem.derived);

            if ident, ok := elem.derived.(ast.Ident); ok {
                return true;
            }

            else if field, ok := elem.derived.(ast.Field_Value); ok {

                if position_in_node(field.value, position_context.position) {
                    return false;
                }

            }

        }

        else {
            log.infof("not in %v", elem.derived);
        }

    }

    return true;
}

field_exists_in_comp_lit :: proc(comp_lit: ^ast.Comp_Lit, name: string) -> bool {

    for elem in comp_lit.elems {

        if field, ok := elem.derived.(ast.Field_Value); ok {

            if field.field != nil {

                if ident, ok := field.field.derived.(ast.Ident); ok {

                    if ident.name == name {
                        return true;
                    }

                }


            }

        }

    }

    return false;
}

get_comp_lit_completion :: proc(ast_context: ^AstContext, position_context: ^DocumentPositionContext, list: ^CompletionList) {

    items := make([dynamic] CompletionItem, context.temp_allocator);

    if position_context.parent_comp_lit.type != nil {

        if symbol, ok := resolve_type_expression(ast_context, position_context.parent_comp_lit.type); ok {

            if comp_symbol, ok := resolve_type_comp_literal(ast_context, position_context, symbol, position_context.parent_comp_lit); ok {

                #partial switch v in comp_symbol.value {
                case index.SymbolStructValue:
                    for name, i in v.names {

                        //ERROR no completion on name and hover
                        if resolved, ok := resolve_type_expression(ast_context, v.types[i]); ok {

                            if field_exists_in_comp_lit(position_context.comp_lit, name) {
                                continue;
                            }

                            resolved.signature = index.node_to_string(v.types[i]);
                            resolved.pkg = comp_symbol.name;
                            resolved.name = name;
                            resolved.type = .Field;

                            item := CompletionItem {
                                label = resolved.name,
                                kind = cast(CompletionItemKind) resolved.type,
                                detail = concatenate_symbols_information(ast_context, resolved),
                                documentation = resolved.doc,
                            };

                            append(&items, item);
                        }
                    }
                }
            }
        }
    }

    list.items = items[:];

    log.info("comp lit completion!");
}

get_selector_completion :: proc(ast_context: ^AstContext, position_context: ^DocumentPositionContext, list: ^CompletionList) {

    items := make([dynamic] CompletionItem, context.temp_allocator);

    ast_context.current_package = ast_context.document_package;

    if ident, ok := position_context.selector.derived.(ast.Ident); ok {

        if !resolve_ident_is_variable(ast_context, ident) && !resolve_ident_is_package(ast_context, ident) {
            return;
        }

    }

    symbols := make([dynamic] index.Symbol, context.temp_allocator);

    selector: index.Symbol;
    ok: bool;

    ast_context.use_locals = true;
    ast_context.use_globals = true;

    selector, ok = resolve_type_expression(ast_context, position_context.selector);

    if !ok {
        log.info(position_context.selector.derived);
        log.error("Failed to resolve type selector in completion list");
        return;
    }

    if selector.pkg != "" {
        ast_context.current_package = selector.pkg;
    }

    else {
        ast_context.current_package = ast_context.document_package;
    }

    field: string;

    if position_context.field != nil {

        switch v in position_context.field.derived {
        case ast.Ident:
            field = v.name;
        }

    }


    if s, ok := selector.value.(index.SymbolProcedureValue); ok {
        if len(s.return_types) == 1 {
            if selector, ok = resolve_type_expression(ast_context, s.return_types[0].type); !ok {
                return;
            }
        }
    }


    #partial switch v in selector.value {
    case index.SymbolEnumValue:
        list.isIncomplete = false;

        for name in v.names {
            symbol: index.Symbol;
            symbol.name = name;
            symbol.type = .EnumMember;
            append(&symbols, symbol);
        }

    case index.SymbolStructValue:
        list.isIncomplete = false;

        for name, i in v.names {

            if selector.pkg != "" {
                ast_context.current_package = selector.pkg;
            }

            else {
                ast_context.current_package = ast_context.document_package;
            }

            if symbol, ok := resolve_type_expression(ast_context, v.types[i]); ok {
                symbol.name = name;
                symbol.type = .Field;
                symbol.pkg = selector.name;
                symbol.signature = index.node_to_string(v.types[i]);
                append(&symbols, symbol);
            }

            else {
                //just give some generic symbol with name.
                symbol: index.Symbol;
                symbol.name = name;
                symbol.type = .Field;
                append(&symbols, symbol);
            }

        }


    case index.SymbolPackageValue:

        list.isIncomplete = true;

        log.infof("search field %v, pkg %v", field, selector.pkg);

        if searched, ok := index.fuzzy_search(field, {selector.pkg}); ok {

            for search in searched {
                append(&symbols, search.symbol);
            }

        }

        else {
            log.errorf("Failed to fuzzy search, field: %v, package: %v", field, selector.pkg);
            return;
        }


    case index.SymbolGenericValue:

        list.isIncomplete = false;

        if ptr, ok := v.expr.derived.(ast.Pointer_Type); ok {

            if symbol, ok := resolve_type_expression(ast_context, ptr.elem); ok {

                #partial switch s in symbol.value {
                case index.SymbolStructValue:
                    for name, i in s.names {
                        //ERROR no completion on name

                        if selector.pkg != "" {
                            ast_context.current_package = selector.pkg;
                        }

                        else {
                            ast_context.current_package = ast_context.document_package;
                        }

                        if symbol, ok := resolve_type_expression(ast_context, s.types[i]); ok {
                            symbol.name = name;
                            symbol.type = .Field;
                            symbol.pkg =  symbol.name;
                            symbol.signature = index.node_to_string(s.types[i]);
                            append(&symbols, symbol);
                        }

                        else {
                            symbol: index.Symbol;
                            symbol.name = name;
                            symbol.type = .Field;
                            append(&symbols, symbol);
                        }
                    }
                }
            }

        }

    }

    for symbol, i in symbols {

        item := CompletionItem {
            label = symbol.name,
            kind = cast(CompletionItemKind) symbol.type,
            detail = concatenate_symbols_information(ast_context, symbol),
            documentation = symbol.doc,
        };

        append(&items, item);
    }

    list.items = items[:];
}

get_implicit_completion :: proc(ast_context: ^AstContext, position_context: ^DocumentPositionContext, list: ^CompletionList) {

    items := make([dynamic] CompletionItem, context.temp_allocator);

    list.isIncomplete = false;

    selector: index.Symbol;

    ast_context.use_locals = true;
    ast_context.use_globals = true;

    if selector.pkg != "" {
        ast_context.current_package = selector.pkg;
    }

    else {
        ast_context.current_package = ast_context.document_package;
    }

    if position_context.binary != nil && (position_context.binary.op.text == "==" || position_context.binary.op.text == "!=") {

        context_node: ^ast.Expr;
        enum_node: ^ast.Expr;

        if position_in_node(position_context.binary.right, position_context.position) {
            context_node = position_context.binary.right;
            enum_node = position_context.binary.left;
        }

        else if position_in_node(position_context.binary.left, position_context.position) {
            context_node = position_context.binary.left;
            enum_node = position_context.binary.right;
        }

        if context_node != nil && enum_node != nil {

            if lhs, ok := resolve_type_expression(ast_context, enum_node); ok {

                #partial switch v in lhs.value {
                case index.SymbolEnumValue:
                    for name in v.names {

                        item := CompletionItem {
                            label = name,
                            kind = .EnumMember,
                            detail = name,
                        };

                        append(&items, item);

                    }

                }

            }

        }

    }

    else if position_context.returns != nil && position_context.function != nil {

        return_index: int;

        if position_context.returns.results == nil {
            return;
        }

        for result, i in position_context.returns.results {

            if position_in_node(result, position_context.position) {
                return_index = i;
                break;
            }

        }

        if position_context.function.type == nil {
            return;
        }

        if position_context.function.type.results == nil {
            return;
        }

        if len(position_context.function.type.results.list) > return_index {

            if return_symbol, ok := resolve_type_expression(ast_context, position_context.function.type.results.list[return_index].type); ok {

                #partial switch v in return_symbol.value {
                case index.SymbolEnumValue:
                    for name in v.names {

                        item := CompletionItem {
                            label = name,
                            kind = .EnumMember,
                            detail = name,
                        };

                        append(&items, item);

                    }

                }

            }

        }




    }


    list.items = items[:];

}

get_identifier_completion :: proc(ast_context: ^AstContext, position_context: ^DocumentPositionContext, list: ^CompletionList) {

    items := make([dynamic] CompletionItem, context.temp_allocator);

    list.isIncomplete = true;

    CombinedResult :: struct {
        score: f32,
        symbol: index.Symbol,
        variable: ^ast.Ident,
    };

    combined_sort_interface :: proc(s: ^[dynamic] CombinedResult) -> sort.Interface {
        return sort.Interface{
            collection = rawptr(s),
            len = proc(it: sort.Interface) -> int {
                s := (^[dynamic] CombinedResult)(it.collection);
                return len(s^);
            },
            less = proc(it: sort.Interface, i, j: int) -> bool {
                s := (^[dynamic] CombinedResult)(it.collection);
                return s[i].score > s[j].score;
            },
            swap = proc(it: sort.Interface, i, j: int) {
                s := (^[dynamic] CombinedResult)(it.collection);
                s[i], s[j] = s[j], s[i];
            },
        };
    }

    combined := make([dynamic] CombinedResult);

    lookup := "";

    if ident, ok := position_context.identifier.derived.(ast.Ident); ok {
        lookup = ident.name;
    }

    pkgs := make([dynamic] string, context.temp_allocator);

    usings := get_using_packages(ast_context);

    for u in usings {
        append(&pkgs, u);
    }

    append(&pkgs, ast_context.document_package);

    if results, ok := index.fuzzy_search(lookup, pkgs[:]); ok {

        for r in results {
            append(&combined, CombinedResult { score = r.score, symbol = r.symbol});
        }

    }

    matcher := common.make_fuzzy_matcher(lookup);

    global: for k, v in ast_context.globals {

        //combined is sorted and should do binary search instead.
        for result in combined {
            if result.symbol.name == k {
                continue global;
            }
        }

        ast_context.use_locals = true;
        ast_context.use_globals = true;
        ast_context.current_package = ast_context.document_package;

        ident := index.new_type(ast.Ident, tokenizer.Pos {}, tokenizer.Pos {}, context.temp_allocator);
        ident.name = k;

        if symbol, ok := resolve_type_identifier(ast_context, ident^); ok {
            symbol.name = ident.name;
            symbol.signature = get_signature(ast_context, ident^, symbol);

            if score, ok := common.fuzzy_match(matcher, symbol.name); ok {
                append(&combined, CombinedResult { score = score * 1.1, symbol = symbol, variable = ident });
            }

        }
    }

    for k, v in ast_context.locals {

        ast_context.use_locals = true;
        ast_context.use_globals = true;
        ast_context.current_package = ast_context.document_package;

        ident := index.new_type(ast.Ident, tokenizer.Pos {}, tokenizer.Pos {}, context.temp_allocator);
        ident.name = k;

        if symbol, ok := resolve_type_identifier(ast_context, ident^); ok {
            symbol.name = ident.name;
            symbol.signature = get_signature(ast_context, ident^, symbol);

            if score, ok := common.fuzzy_match(matcher, symbol.name); ok {
                append(&combined, CombinedResult { score = score * 1.1, symbol = symbol, variable = ident });
            }

        }
    }

    for pkg in ast_context.imports {

        symbol: index.Symbol;

        symbol.name = pkg.base;
        symbol.type = .Package;

        if score, ok := common.fuzzy_match(matcher, symbol.name); ok {
            append(&combined,  CombinedResult { score = score * 1.1, symbol = symbol });
        }
    }

    sort.sort(combined_sort_interface(&combined));

    //hard code for now
    top_results := combined[0:(min(20, len(combined)))];

    for result in top_results {

        item := CompletionItem {
            label = result.symbol.name,
            detail = concatenate_symbols_information(ast_context, result.symbol),
        };

        if result.variable != nil {
            if ok := resolve_ident_is_variable(ast_context, result.variable^); ok {
                item.kind = .Variable;
            }

            else {
                item.kind = cast(CompletionItemKind)result.symbol.type;
            }
        }

        else {
            item.kind = cast(CompletionItemKind)result.symbol.type;
        }

        append(&items, item);
    }

    list.items = items[:];
}

