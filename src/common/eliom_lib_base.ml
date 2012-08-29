(* Ocsigen
 * http://www.ocsigen.org
 * Copyright (C) 2011 Grégoire Henry
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

open Ocsigen_lib_base

exception Eliom_Internal_Error of string

module Lwt_ops = struct
  let (>>=) = Lwt.(>>=)
  let (=<<) = Lwt.(=<<)
  let (>|=) = Lwt.(>|=)
  let (=|<) = Lwt.(=|<)
end

let fresh_ix () =
  Oo.id (object end)

let get_option = function
  | Some x -> x
  | None -> failwith "get_option"

let escape_quotes s =
  let b = Buffer.create (2 * String.length s) in
  String.iter
    (function
       | '"' -> Buffer.add_string b "\\\""
       | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(**/**)

module RawXML = struct

  type separator = Space | Comma

  let separator_to_string = function
    | Space -> " "
    | Comma -> ", "

  type cookie_info = (bool * string list) deriving (Json)

  type -'a caml_event_handler =
    | CE_registered_closure of string * ((#Dom_html.event as 'a) Js.t -> unit) Eliom_server.Client_value.t
    | CE_client_closure of ('a Js.t -> unit) (* Client side-only *)
    | CE_call_service of
        ([ `A | `Form_get | `Form_post] * (cookie_info option) * string option) option Eliom_lazy.request

  type event_handler =
    | Raw of string
    | Caml of Dom_html.event caml_event_handler

  type uri = string Eliom_lazy.request
  let string_of_uri = Eliom_lazy.force
  let uri_of_string = Eliom_lazy.from_val
  let uri_of_fun = Eliom_lazy.from_fun

  let event_handler_of_string s = Raw s
  let string_of_event_handler = function
    | Raw s -> s
    | Caml _ -> "/* Invalid Caml value */"
  let event_handler_of_service info = Caml (CE_call_service info)

  (* Deprecated alias. *)
  let event_of_service = event_handler_of_service
  let event_of_string = event_handler_of_string
  let string_of_handler = string_of_event_handler

  let ce_registered_closure_class = "caml_closure"
  let ce_call_service_class = "caml_link"
  let process_node_class = "caml_process_node"
  let request_node_class = "caml_request_node"

  let ce_call_service_attrib = "data-eliom-cookies-info"
  let ce_template_attrib = "data-eliom-template"
  let node_id_attrib = "data-eliom-node-id"

  let closure_attr_prefix = "caml_closure_id"
  let closure_attr_prefix_len = String.length closure_attr_prefix

  type aname = string
  type acontent =
    | AFloat of float
    | AInt of int
    | AStr of string
    | AStrL of separator * string list
  type racontent =
    | RA of acontent
    | RACamlEventHandler of Dom_html.event caml_event_handler
    | RALazyStr of string Eliom_lazy.request
    | RALazyStrL of separator * string Eliom_lazy.request list
  type attrib = aname * racontent
  let aname (name, _) = name
  let acontent = function
    | _, RA a -> a
    | _, RACamlEventHandler (CE_registered_closure (crypto, _)) ->
      AStr (closure_attr_prefix^crypto)
    | _, RACamlEventHandler _ -> AStr ("")
    | _, RALazyStr str -> AStr (Eliom_lazy.force str)
    | _, RALazyStrL (sep, str) -> AStrL (sep, List.map Eliom_lazy.force str)
  let racontent (_, a) = a

  let float_attrib name value = name, RA (AFloat value)
  let int_attrib name value = name, RA (AInt value)
  let string_attrib name value = name, RA (AStr value)
  let space_sep_attrib name values = name, RA (AStrL (Space, values))
  let comma_sep_attrib name values = name, RA (AStrL (Comma, values))
  let event_handler_attrib name value = match value with
    | Raw value -> name, RA (AStr value)
    | Caml v -> name, RACamlEventHandler v
  let uri_attrib name value = name, RALazyStr value
  let uris_attrib name value = name, RALazyStrL (Space, value)

  (* Deprecated alias. *)
  let event_attrib = event_handler_attrib

  type ename = string
  type node_id =
    | NoId
    | ProcessId of string
    | RequestId of string

  module ClosureMap = Map.Make(struct type t = string let compare = compare end)

  type event_handler_table =
    ((Dom_html.event Js.t -> unit) Eliom_server.Client_value.t) ClosureMap.t

  let filter_class (acc_class,acc_attr) = function
    | "class", RA value ->
      begin
        match value with
          | AStr v ->
            (v::acc_class,acc_attr)
          | AStrL (Space,v) ->
            (v@acc_class,acc_attr)
          | _ -> failwith "attribute class is not a string"
      end
    | _, RACamlEventHandler (CE_registered_closure _) as attr ->
      (ce_registered_closure_class :: acc_class, attr :: acc_attr)
    | _, RACamlEventHandler (CE_call_service link_info) ->
      begin
        match Eliom_lazy.force link_info with
          | None -> acc_class, acc_attr
          | Some (kind,cookie_info,tmpl) ->
              ce_call_service_class::acc_class,
              let acc_attr =
                match cookie_info with
                | None -> acc_attr
                | Some v ->
                    (ce_call_service_attrib, RA (AStr (Json.to_string<cookie_info> v)))
                    :: acc_attr
              in
              match tmpl with
              | None -> acc_attr
              | Some tmpl -> (ce_template_attrib, RA (AStr tmpl)) :: acc_attr
      end
    | attr -> (acc_class,attr::acc_attr)

  let filter_class_attribs node_id attribs =
    let node_id = match node_id with
      | NoId -> [],[]
      | ProcessId i -> [process_node_class], [node_id_attrib,RA (AStr i)]
      | RequestId i -> [request_node_class], [node_id_attrib,RA (AStr i)]
    in
    let (classes,attribs) =
      List.fold_left filter_class (node_id) attribs in
    match classes with
      | [] -> attribs
      | _ -> ("class",RA (AStrL(Space,classes)))::attribs

end

let tyxml_unwrap_id_int = 1
let client_value_unwrap_id_int = 7

type escaped_value = poly

(**/**)

module Map_make (Ord : Map.OrderedType) = struct
  include Map.Make (Ord)
  let from_list li =
    List.fold_right (uncurry add) li empty
end

module Int64_map = Map_make (Int64)
module Int_map = Map_make (struct type t = int let compare = (-) end)
module String_map = Map_make (String)


module Client_value_data_base = struct
  type base = (int64 * int * poly) list
  let unwrap_id_int = 8
end

module Injection_data_base = struct
  type base = (string * poly) list
  let unwrap_id_int = 9
end

let debug_client_value_data f client_value_data =
  Printf.ksprintf f "Client value data: %s"
    (String.concat ", "
       (List.map
          (fun (closure_id, instance_id, _) ->
             Printf.sprintf "%Ld/%d" closure_id instance_id)
          client_value_data))

let debug_injection_data f injection_data =
  Printf.ksprintf f "Injection data: %s"
    (String.concat ","
       (List.map fst injection_data));
