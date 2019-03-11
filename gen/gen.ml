(* Automatically generate the C++ -> C -> rust bindings.
   This takes as input the Descriptions.yaml file that gets generated when
   building PyTorch from source.

   Run with: dune exec gen/gen.exe
 *)
open Base
open Stdio

let excluded_functions =
  Set.of_list
    (module String)
    [ "multi_margin_loss"
    ; "multi_margin_loss_out"
    ; "log_softmax_backward_data"
    ; "softmax_backward_data" ]

let prefixed_functions =
  Set.of_list
    (module String)
    ["add"; "add_"; "div"; "div_"; "mul"; "mul_"; "sub"; "sub_"; "nll_loss"]

let excluded_prefixes = ["_"; "thnn_"; "th_"]

let excluded_suffixes = ["_forward"; "_forward_out"]

let yaml_error yaml ~msg =
  Printf.failwithf "%s, %s" msg (Yaml.to_string_exn yaml) ()

let extract_bool = function
  | `Bool b -> b
  | `String "true" -> true
  | `String "false" -> false
  | yaml -> yaml_error yaml ~msg:"expected bool"

let extract_list = function
  | `A l -> l
  | yaml -> yaml_error yaml ~msg:"expected list"

let extract_map = function
  | `O map -> Map.of_alist_exn (module String) map
  | yaml -> yaml_error yaml ~msg:"expected map"

let extract_string = function
  | `String s -> s
  | yaml -> yaml_error yaml ~msg:"expected string"

module Func = struct
  type arg_type =
    | Bool
    | Int64
    | Double
    | Tensor
    | TensorOption
    | IntList
    | TensorList
    | TensorOptions
    | Scalar
    | ScalarType
    | Device

  type arg =
    {arg_name: string; arg_type: arg_type; default_value: string option}

  type t =
    { name: string
    ; args: arg list
    ; returns: int (* number of tensors that are returned *)
    ; kind: [`function_ | `method_] }

  let arg_type_of_string str ~is_nullable =
    match String.lowercase str with
    | "bool" -> Some Bool
    | "int64_t" -> Some Int64
    | "double" -> Some Double
    | "booltensor" | "indextensor" | "tensor" ->
        Some (if is_nullable then TensorOption else Tensor)
    | "tensoroptions" -> Some TensorOptions
    | "intlist" -> Some IntList
    | "tensorlist" -> Some TensorList
    | "device" -> Some Device
    | "scalar" -> Some Scalar
    | "scalartype" -> Some ScalarType
    | _ -> None

  let c_typed_args_list t =
    List.map t.args ~f:(fun {arg_name; arg_type; _} ->
        match arg_type with
        | IntList ->
            Printf.sprintf "int64_t *%s_data, int %s_len" arg_name arg_name
        | TensorList ->
            Printf.sprintf "tensor *%s_data, int %s_len" arg_name arg_name
        | TensorOptions ->
            Printf.sprintf "int %s_kind, int %s_device" arg_name arg_name
        | otherwise ->
            let simple_type_cstring =
              match otherwise with
              | Bool -> "int"
              | Int64 -> "int64_t"
              | Double -> "double"
              | Tensor -> "tensor"
              | TensorOption -> "tensor"
              | ScalarType -> "int"
              | Device -> "int"
              | Scalar -> "scalar"
              | IntList | TensorList | TensorOptions -> assert false
            in
            Printf.sprintf "%s %s" simple_type_cstring arg_name )
    |> String.concat ~sep:", "

  let c_args_list args =
    List.map args ~f:(fun {arg_name; arg_type; _} ->
        match arg_type with
        | Scalar | Tensor -> "*" ^ arg_name
        | TensorOption ->
            Printf.sprintf "(%s ? *%s : torch::Tensor())" arg_name arg_name
        | Bool -> "(bool)" ^ arg_name
        | IntList ->
            Printf.sprintf "torch::IntList(%s_data, %s_len)" arg_name arg_name
        | TensorList ->
            Printf.sprintf "of_carray_tensor(%s_data, %s_len)" arg_name
              arg_name
        | TensorOptions ->
            Printf.sprintf
              "at::device(at::DeviceType(%s_device)).dtype(at::ScalarType(%s_kind))"
              arg_name arg_name
        | ScalarType -> Printf.sprintf "torch::ScalarType(%s)" arg_name
        | Device ->
            Printf.sprintf "torch::Device(torch::DeviceType(%s))" arg_name
        | _ -> arg_name )
    |> String.concat ~sep:", "

  let c_call t =
    match t.kind with
    | `function_ -> Printf.sprintf "torch::%s(%s)" t.name (c_args_list t.args)
    | `method_ -> (
      match t.args with
      | head :: tail ->
          Printf.sprintf "%s->%s(%s)" head.arg_name t.name (c_args_list tail)
      | [] ->
          Printf.failwithf "Method calls should have at least one argument %s"
            t.name () )

  let replace_map =
    Map.of_alist_exn
      (module String)
      [("end", "end_"); ("to", "to_"); ("t", "tr"); ("where", "where_")]

  let rust_name name =
    Map.find replace_map name |> Option.value ~default:name |> String.lowercase

  let c_rust_args_list t =
    List.map t.args ~f:(fun arg ->
        let an = arg.arg_name in
        let single_param = Printf.sprintf "%s_: %s" an in
        match arg.arg_type with
        | Bool -> single_param "c_int"
        | Int64 -> single_param "i64"
        | Double -> single_param "f64"
        | Tensor -> single_param "*mut C_tensor"
        | TensorOption -> single_param "*mut C_tensor"
        | Scalar -> single_param "*mut C_scalar"
        | ScalarType -> single_param "c_int"
        | Device -> single_param "c_int"
        | IntList -> Printf.sprintf "%s_data: *const i64, %s_len: c_int" an an
        | TensorList ->
            Printf.sprintf "%s_data: *const *mut C_tensor, %s_len: c_int" an an
        | TensorOptions ->
            Printf.sprintf "%s_kind: c_int, %s_device: c_int" an an )
    |> String.concat ~sep:", "

  let self_name = "self"

  let input_name = "input"

  let self_tensor arg =
    match arg.arg_type with
    | Tensor -> String.( = ) arg.arg_name self_name
    | _ -> false

  let input_tensor arg =
    match arg.arg_type with
    | Tensor -> String.( = ) arg.arg_name input_name
    | _ -> false

  let type_parameters t =
    let needs_scalar_parameter =
      List.exists t.args ~f:(fun arg ->
          match arg.arg_type with Scalar -> true | _ -> false )
    in
    let needs_type_parameter =
      List.exists t.args ~f:(fun arg ->
          match arg.arg_type with
          | TensorList | TensorOption -> true
          | _ -> false )
    in
    if needs_type_parameter && needs_scalar_parameter then
      "<T: Borrow<Tensor>, S: AsScalar>"
    else if needs_type_parameter then "<T: Borrow<Tensor>>"
    else if needs_scalar_parameter then "<S: AsScalar>"
    else ""

  let rust_args_list t =
    match List.partition_tf t.args ~f:self_tensor with
    | [self], args_list -> (Some self, args_list)
    | _, _ -> (
      match List.partition_tf t.args ~f:input_tensor with
      | [self], args_list -> (Some self, args_list)
      | _, _ -> (None, t.args) )

  let rust_typed_args_list t =
    let to_string args =
      List.map args ~f:(fun arg ->
          let rust_arg_type =
            match arg.arg_type with
            | Bool -> "bool"
            | Int64 -> "i64"
            | Double -> "f64"
            | Tensor -> "&Tensor"
            | TensorOption -> "Option<T>"
            | IntList -> "&[i64]"
            | TensorList -> "&[T]"
            | TensorOptions -> "(Kind, Device)"
            | Scalar -> "S"
            | ScalarType -> "Kind"
            | Device -> "Device"
          in
          Printf.sprintf "%s: %s" (rust_name arg.arg_name) rust_arg_type )
      |> String.concat ~sep:", "
    in
    match List.partition_tf t.args ~f:self_tensor with
    | [self], args_list ->
        (Some self.arg_name, Printf.sprintf "&self, %s" (to_string args_list))
    | _, _ -> (
      match List.partition_tf t.args ~f:input_tensor with
      | [self], args_list ->
          (Some self.arg_name, Printf.sprintf "&self, %s" (to_string args_list))
      | _, _ -> (None, to_string t.args) )

  let rust_return_type t ~fallible =
    let returns =
      match t.returns with
      | 0 -> None
      | 1 -> Some "Tensor"
      | v ->
          Some
            ( List.init v ~f:(fun _ -> "Tensor")
            |> String.concat ~sep:", " |> Printf.sprintf "(%s)" )
    in
    match returns with
    | Some returns ->
        if fallible then Printf.sprintf " -> failure::Fallible<%s>" returns
        else Printf.sprintf " -> %s" returns
    | None -> ""

  let rust_binding_args t ~self =
    List.map t.args ~f:(fun arg ->
        let name =
          if
            Option.value_map self ~default:false ~f:(String.( = ) arg.arg_name)
          then "self"
          else rust_name arg.arg_name
        in
        match arg.arg_type with
        | Tensor -> Printf.sprintf "%s.c_tensor" name
        | Scalar -> Printf.sprintf "%s.as_scalar().c_scalar" name
        | Bool -> Printf.sprintf "if %s { 1 } else { 0 }" name
        | ScalarType -> Printf.sprintf "%s.c_int()" name
        | Device -> Printf.sprintf "%s.c_int()" name
        | TensorOptions ->
            Printf.sprintf "%s.0.c_int(), %s.1.c_int()" name name
        | IntList -> Printf.sprintf "%s.as_ptr(), %s.len() as i32" name name
        | TensorList ->
            Printf.sprintf "ptr_list(%s).as_ptr(), %s.len() as i32" name name
        | TensorOption ->
            Printf.sprintf
              "%s.map_or(std::ptr::null_mut(), |t| t.borrow().c_tensor)" name
        | _ -> name )
    |> String.concat ~sep:",\n                "
end

exception Not_a_simple_arg

let read_yaml filename =
  let funcs =
    (* Split the file to avoid Yaml.of_string_exn segfaulting. *)
    In_channel.with_file filename ~f:In_channel.input_lines
    |> List.group ~break:(fun _ l ->
           String.length l > 0 && Char.( = ) l.[0] '-' )
    |> List.concat_map ~f:(fun lines ->
           Yaml.of_string_exn (String.concat lines ~sep:"\n") |> extract_list
       )
  in
  printf "Read %s, got %d functions.\n%!" filename (List.length funcs) ;
  List.filter_map funcs ~f:(fun yaml ->
      let map = extract_map yaml in
      let name = Map.find_exn map "name" |> extract_string in
      let deprecated = Map.find_exn map "deprecated" |> extract_bool in
      let method_of =
        Map.find_exn map "method_of"
        |> extract_list |> List.map ~f:extract_string
      in
      let arguments = Map.find_exn map "arguments" |> extract_list in
      let returns =
        let is_tensor returns =
          let returns = extract_map returns in
          let return_type =
            Map.find_exn returns "dynamic_type" |> extract_string
          in
          String.( = ) return_type "Tensor"
          || String.( = ) return_type "BoolTensor"
          || String.( = ) return_type "IndexTensor"
        in
        let returns = Map.find_exn map "returns" |> extract_list in
        if List.for_all returns ~f:is_tensor then Some (List.length returns)
        else None
      in
      let kind =
        if List.exists method_of ~f:(String.( = ) "namespace") then
          Some `function_
        else if List.exists method_of ~f:(String.( = ) "Tensor") then
          Some `method_
        else None
      in
      if
        (not deprecated)
        && (not
              (List.exists excluded_prefixes ~f:(fun prefix ->
                   String.is_prefix name ~prefix )))
        && (not
              (List.exists excluded_suffixes ~f:(fun suffix ->
                   String.is_suffix name ~suffix )))
        && not (Set.mem excluded_functions name)
      then
        Option.both returns kind
        |> Option.bind ~f:(fun (returns, kind) ->
               try
                 let args =
                   List.filter_map arguments ~f:(fun arg ->
                       let arg = extract_map arg in
                       let arg_name =
                         Map.find_exn arg "name" |> extract_string
                       in
                       let arg_type =
                         Map.find_exn arg "dynamic_type" |> extract_string
                       in
                       let is_nullable =
                         Map.find arg "is_nullable"
                         |> Option.value_map ~default:false ~f:extract_bool
                       in
                       let default_value =
                         Map.find arg "default" |> Option.map ~f:extract_string
                       in
                       match Func.arg_type_of_string arg_type ~is_nullable with
                       | Some Scalar
                         when Option.is_some default_value && not is_nullable
                         ->
                           None
                       | Some arg_type ->
                           let arg_name =
                             match (arg_name, arg_type) with
                             | "self", Scalar -> "self_scalar"
                             | _, _ -> arg_name
                           in
                           Some {Func.arg_name; arg_type; default_value}
                       | None ->
                           if Option.is_some default_value then None
                           else raise Not_a_simple_arg )
                 in
                 Some {Func.name; args; returns; kind}
               with Not_a_simple_arg -> None )
      else None )

let p out_channel s =
  Printf.ksprintf
    (fun line ->
      Out_channel.output_string out_channel line ;
      Out_channel.output_char out_channel '\n' )
    s

let write_cpp funcs filename =
  Out_channel.with_file (filename ^ ".cpp.h") ~f:(fun out_cpp ->
      Out_channel.with_file (filename ^ ".h") ~f:(fun out_h ->
          let pc s = p out_cpp s in
          let ph s = p out_h s in
          pc "// THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND!" ;
          pc "" ;
          ph "// THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND!" ;
          ph "" ;
          Map.iteri funcs ~f:(fun ~key:exported_name ~data:func ->
              let c_typed_args_list = Func.c_typed_args_list func in
              pc "void atg_%s(tensor *out__, %s) {" exported_name
                c_typed_args_list ;
              pc "  PROTECT(" ;
              pc "    auto outputs__ = %s;" (Func.c_call func) ;
              if func.returns = 1 then
                pc "    out__[0] = new torch::Tensor(outputs__);"
              else
                for i = 0 to func.returns - 1 do
                  pc
                    "    out__[%d] = new \
                     torch::Tensor(std::get<%d>(outputs__));"
                    i i
                done ;
              pc "  )" ;
              pc "}" ;
              pc "" ;
              ph "void atg_%s(tensor *, %s);" exported_name c_typed_args_list
          ) ) )

let write_fallible_wrapper funcs filename =
  Out_channel.with_file filename ~f:(fun out_ml ->
      let pm s = p out_ml s in
      pm "/* THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND! */" ;
      pm "#[allow(clippy::all)]" ;
      pm "use torch_sys::*;" ;
      pm "use torch_sys::c_generated::*;" ;
      pm "use crate::device::Device;" ;
      pm "use crate::kind::Kind;" ;
      pm "use crate::scalar::AsScalar;" ;
      pm "use std::borrow::Borrow;" ;
      pm "use super::c_wrapper::Tensor;" ;
      pm "" ;
      pm "fn ptr_list<T: Borrow<Tensor>>(l: &[T]) -> Vec<*mut C_tensor> {" ;
      pm "    l.iter().map(|x| x.borrow().c_tensor).collect()" ;
      pm "}" ;
      pm "" ;
      pm "impl Tensor {" ;
      Map.iteri funcs ~f:(fun ~key:exported_name ~data:(func : Func.t) ->
          let rust_name = Func.rust_name exported_name in
          let returns =
            match func.returns with
            | 0 -> ""
            | 1 -> "Tensor { c_tensor: c_tensors[0] }"
            | n ->
                List.init n
                  ~f:(Printf.sprintf "Tensor { c_tensor: c_tensors[%d] }")
                |> String.concat ~sep:", " |> Printf.sprintf "(%s)"
          in
          pm "" ;
          pm "    pub fn f_%s%s(" rust_name (Func.type_parameters func) ;
          let self, rust_args_list = Func.rust_typed_args_list func in
          pm "        %s" rust_args_list ;
          pm "    )%s {" (Func.rust_return_type func ~fallible:true) ;
          pm "        let mut c_tensors = [std::ptr::null_mut(); %d];"
            func.returns ;
          pm "        unsafe_torch_err!({" ;
          pm "            atg_%s(c_tensors.as_mut_ptr()," exported_name ;
          pm "                %s" (Func.rust_binding_args func ~self) ;
          pm "            ) });" ;
          pm "        Ok(%s)" returns ;
          pm "    }" ) ;
      pm "}" )

let write_wrapper funcs filename =
  Out_channel.with_file filename ~f:(fun out_ml ->
      let pm s = p out_ml s in
      pm "/* THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND! */" ;
      pm "#[allow(clippy::all)]" ;
      pm "use crate::device::Device;" ;
      pm "use crate::kind::Kind;" ;
      pm "use crate::scalar::AsScalar;" ;
      pm "use std::borrow::Borrow;" ;
      pm "use super::c_wrapper::Tensor;" ;
      pm "" ;
      pm "impl Tensor {" ;
      Map.iteri funcs ~f:(fun ~key:exported_name ~data:(func : Func.t) ->
          let rust_name = Func.rust_name exported_name in
          let rust_name, fallible_rust_name =
            if Set.mem prefixed_functions func.name then
              ("g_" ^ rust_name, "f_" ^ rust_name)
            else (rust_name, "f_" ^ rust_name)
          in
          pm "" ;
          pm "    pub fn %s%s(" rust_name (Func.type_parameters func) ;
          let _self, rust_args_list = Func.rust_typed_args_list func in
          pm "        %s" rust_args_list ;
          pm "    )%s {" (Func.rust_return_type func ~fallible:false) ;
          let self, rust_args_list = Func.rust_args_list func in
          let self = if Option.is_some self then "self." else "Tensor::" in
          let rust_args_list =
            List.map rust_args_list ~f:(fun arg ->
                Func.rust_name arg.Func.arg_name )
            |> String.concat ~sep:", "
          in
          pm "        %s%s(%s).unwrap()" self fallible_rust_name rust_args_list ;
          pm "    }" ) ;
      pm "}" )

let write_ffi funcs filename =
  Out_channel.with_file filename ~f:(fun out_ml ->
      let pm s = p out_ml s in
      pm "/* THIS FILE IS AUTOMATICALLY GENERATED, DO NOT EDIT BY HAND! */" ;
      pm "#[allow(clippy::all)]" ;
      pm "use crate::{C_scalar, C_tensor};" ;
      pm "use libc::c_int;" ;
      pm "" ;
      pm "extern \"C\" {" ;
      Map.iteri funcs ~f:(fun ~key:exported_name ~data:func ->
          pm "    pub fn atg_%s(out__: *mut *mut C_tensor, %s);" exported_name
            (Func.c_rust_args_list func) ) ;
      pm "}" )

let methods =
  let c name args = {Func.name; args; returns= 1; kind= `method_} in
  let ca arg_name arg_type = {Func.arg_name; arg_type; default_value= None} in
  [ c "grad" [ca "self" Tensor]
  ; c "set_requires_grad" [ca "self" Tensor; ca "r" Bool]
  ; c "toType" [ca "self" Tensor; ca "scalar_type" ScalarType]
  ; c "to" [ca "self" Tensor; ca "device" Device] ]

let run ~yaml_filename ~cpp_filename ~ffi_filename ~wrapper_filename
    ~fallible_wrapper_filename =
  let funcs = read_yaml yaml_filename in
  let funcs = methods @ funcs in
  printf "Generating code for %d functions.\n%!" (List.length funcs) ;
  (* Generate some unique names for overloaded functions. *)
  let funcs =
    List.map funcs ~f:(fun func -> (String.lowercase func.name, func))
    |> Map.of_alist_multi (module String)
    |> Map.to_alist
    |> List.concat_map ~f:(fun (name, funcs) ->
           match funcs with
           | [] -> assert false
           | [func] -> [(name, func)]
           | funcs ->
               List.sort funcs ~compare:(fun (f1 : Func.t) (f2 : Func.t) ->
                   Int.compare (List.length f1.args) (List.length f2.args) )
               |> List.mapi ~f:(fun i func ->
                      ( (if i = 0 then name else Printf.sprintf "%s%d" name i)
                      , func ) ) )
    |> Map.of_alist_exn (module String)
  in
  write_cpp funcs cpp_filename ;
  write_ffi funcs ffi_filename ;
  write_wrapper funcs wrapper_filename ;
  write_fallible_wrapper funcs fallible_wrapper_filename

let () =
  run ~yaml_filename:"data/Declarations.yaml"
    ~cpp_filename:"torch-sys/libtch/torch_api_generated"
    ~ffi_filename:"torch-sys/src/c_generated.rs"
    ~wrapper_filename:"src/tensor/c_wrapper_generated.rs"
    ~fallible_wrapper_filename:"src/tensor/c_fallible_wrapper_generated.rs"
