(* Ocsigen
 * http://www.ocsigen.org
 * Copyright (C) 2010 Vincent Balat
 * Copyright (C) 2011 Jérôme Vouillon, Grégoire Henry, Pierre Chambart
 * Copyright (C) 2012 Benedikt Becker
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

include Eliom_client0
(* TODO: Implement better separation between Eliom_client0 and Eliom_client.
   Eliom_client0 is supposed to be linked early, before Eliom_service,
   in order to make possible to use the client-server syntax in Eliom itself.
*)

open Eliom_lib

type ('a, +'b) server_function = 'a -> 'b Lwt.t

(* Logs *)
let section = Lwt_log.Section.make "eliom:client"
let log_section = section
let _ = Lwt_log.Section.set_level log_section Lwt_log.Info
(* *)

let insert_base page =
  let b = Dom_html.createBase Dom_html.document in
  b##href <- Js.string (Eliom_process.get_base_url ());
  b##id <- Js.string Eliom_common_base.base_elt_id;
  Js.Opt.case
    page##querySelector(Js.string "head")
    (fun () -> Lwt_log.ign_debug_f "No <head> found in document")
    (fun head -> Dom.appendChild head b)

let get_global_data () =
  let def () = None
  and id = Js.string "__global_data" in
  Js.Optdef.case (Dom_html.window##localStorage) def @@ fun storage ->
  Js.Opt.case (storage##getItem(id)) def @@ fun v ->
  Lwt_log.ign_debug_f "Unwrap __global_data";
  match
    Eliom_unwrap.unwrap (Url.decode (Js.to_string v)) 0
  with
  | {Eliom_client_common.ecs_data = `Success v} ->
    Lwt_log.ign_debug_f "Unwrap __global_data success";
    Some v
  | _ ->
    None

let init_client_app
    ~app_name ?(ssl = false) ~hostname ?(port = 80) ~full_path () =
  Lwt_log.ign_debug_f "Eliom_client.init_client_app called.";
  Eliom_process.appl_name_r := Some app_name;
  Eliom_request_info.client_app_initialised := true;
  Eliom_process.set_sitedata
    {Eliom_types.site_dir = full_path;
     site_dir_string = String.concat "/" full_path};
  Eliom_process.set_info {Eliom_common.cpi_ssl = ssl ;
                          cpi_hostname = hostname;
                          cpi_server_port = port;
                          cpi_original_full_path = full_path
                         };
  Eliom_process.set_request_template None;
  (* We set the tab cookie table, with the app name inside: *)
  Eliom_process.set_request_cookies
    (Ocsigen_cookies.Cookies.add
       []
       (Ocsigen_cookies.CookiesTable.add
          Eliom_common.appl_name_cookie_name
          (Eliommod_cookies.OSet (None, app_name, false))
          Ocsigen_cookies.CookiesTable.empty)
       Ocsigen_cookies.Cookies.empty);
  ignore (get_global_data ())

let is_client_app () = !Eliom_common.is_client_app

let _ =
  Eliom_common.is_client_app :=
    (* Testing if variable __eliom_appl_process_info exists: *)
    Js.Unsafe.global##___eliom_appl_process_info_foo = Js.undefined

let _ =
  (* Initialize client app if the __eliom_server variable is defined *)
  if is_client_app ()
  && Js.Unsafe.global##___eliom_server_ <> Js.undefined
  && Js.Unsafe.global##___eliom_app_name_ <> Js.undefined
  then begin
    let app_name = Js.to_string (Js.Unsafe.global##___eliom_app_name_) in
    match
      Url.url_of_string (Js.to_string (Js.Unsafe.global##___eliom_server_))
    with
    | Some (Http { hu_host; hu_port; hu_path; _ }) ->
      init_client_app
        ~app_name
        ~ssl:false ~hostname:hu_host ~port:hu_port ~full_path:hu_path ()
    | Some (Https { hu_host; hu_port; hu_path; _ }) ->
      init_client_app
        ~app_name
        ~ssl:true ~hostname:hu_host ~port:hu_port ~full_path:hu_path ()
    | _ -> ()
  end


(* Function called (in Eliom_client_main), once when starting the app.
   Either when sent by a server or initiated on client side. *)
let init () =
  let js_data = Eliom_request_info.get_request_data () in

  (* <base> *)
  (* The first time we load the page, we record the initial URL in a client
     side ref, in order to set <base> (on client-side) in header for each
     pages. *)
  Eliom_process.set_base_url (Js.to_string (Dom_html.window##location##href));
  insert_base Dom_html.document;
  (* </base> *)

  (* Decoding tab cookies.
     2016-03 This was done at the beginning of onload below
     but this makes it impossible to use cookies
     during initialisation phase. I move this here. -- Vincent *)
  Eliommod_cookies.update_cookie_table
    (Some (Eliom_process.get_info ()).cpi_hostname)
    (Eliom_request_info.get_request_cookies ());

  let onload ev =
    Lwt_log.ign_debug ~section "onload (client main)";
    set_initial_load ();
    Lwt.async
      (fun () ->
         if !Eliom_config.debug_timings
         then Firebug.console##time(Js.string "onload");
         Eliom_request_info.set_session_info js_data.Eliom_common.ejs_sess_info;
         (* Give the browser the chance to actually display the page NOW *)
         lwt () = Lwt_js.sleep 0.001 in
         (* Ordering matters. See [Eliom_client.set_content] for explanations *)
         relink_request_nodes (Dom_html.document##documentElement);
         let root = Dom_html.document##documentElement in
         let closure_nodeList,attrib_nodeList =
           relink_page_but_client_values root
         in
         do_request_data js_data.Eliom_common.ejs_request_data;
         (* XXX One should check that all values have been unwrapped.
            In fact, client values should be special and all other values
            should be eagerly unwrapped. *)
         let () =
           relink_attribs root
             js_data.Eliom_common.ejs_client_attrib_table attrib_nodeList in

         let onload_closure_nodes =
           relink_closure_nodes
             root js_data.Eliom_common.ejs_event_handler_table
             closure_nodeList
         in
         reset_request_nodes ();
         Eliommod_dom.add_formdata_hack_onclick_handler ();
         Lwt_mutex.unlock load_mutex;
         run_callbacks
           (flush_onload () @ [ onload_closure_nodes; broadcast_load_end ]);
         if !Eliom_config.debug_timings
         then Firebug.console##timeEnd(Js.string "onload");
         Lwt.return ());
    Js._false
  in

  Lwt_log.ign_debug ~section "Set load/onload events";

  let onunload _ =
    update_state ();
    (* running remaining callbacks, if onbeforeunload left some *)
    let _ = run_onunload ~final:true () in
    Js._true

  and onbeforeunload e =
    match run_onunload ~final:false () with
    | None ->
      update_state (); None
    | r ->
      r
  in

  ignore
    (Dom.addEventListener Dom_html.window (Dom.Event.make "load")
       (Dom.handler onload) Js._true);

  add_string_event_listener Dom_html.window "beforeunload"
    onbeforeunload false;

  ignore
    (Dom.addEventListener Dom_html.window (Dom.Event.make "unload")
       (Dom_html.handler onunload) Js._false)


(* == Low-level: call service. *)

let create_request_
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?nl_params ?keep_get_na_params
    get_params post_params =

  (* TODO: allow get_get_or_post service to return also the service
     with the correct subtype. Then do use Eliom_uri.make_string_uri
     and Eliom_uri.make_post_uri_components instead of Eliom_uri.make_string_uri_
     and Eliom_uri.make_post_uri_components__ *)

  match Eliom_service.get_get_or_post service with
  | `Get ->
    let uri =
      Eliom_uri.make_string_uri_
        ?absolute ?absolute_path ?https
        ~service
        ?hostname ?port ?fragment ?keep_nl_params ?nl_params get_params
    in
    `Get uri
  | `Post | `Put | `Delete as http_method ->
    let path, get_params, fragment, post_params =
      Eliom_uri.make_post_uri_components__
        ?absolute ?absolute_path ?https
        ~service
        ?hostname ?port ?fragment ?keep_nl_params ?nl_params
        ?keep_get_na_params get_params post_params
    in
    let uri =
      Eliom_uri.make_string_uri_from_components (path, get_params, fragment)
    in
    (match http_method with
     | `Post -> `Post (uri, post_params)
     | `Put -> `Put (uri, post_params)
     | `Delete -> `Delete (uri, post_params))

let raw_call_service
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?nl_params ?keep_get_na_params
    ?progress ?upload_progress ?override_mime_type
    get_params post_params =
  lwt uri, content =
    match create_request_
            ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
            ?keep_nl_params ?nl_params ?keep_get_na_params
            get_params post_params
    with
    | `Get uri ->
        Eliom_request.http_get
          ?cookies_info:(Eliom_uri.make_cookies_info (https, service)) uri []
          ?progress ?upload_progress ?override_mime_type
          Eliom_request.string_result
    | `Post (uri, post_params) ->
      Eliom_request.http_post
        ?cookies_info:(Eliom_uri.make_cookies_info (https, service))
        ?progress ?upload_progress ?override_mime_type
        uri post_params Eliom_request.string_result
    | `Put (uri, post_params) ->
      Eliom_request.http_put
        ?cookies_info:(Eliom_uri.make_cookies_info (https, service))
        ?progress ?upload_progress ?override_mime_type
        uri post_params Eliom_request.string_result
    | `Delete (uri, post_params) ->
      Eliom_request.http_delete
        ?cookies_info:(Eliom_uri.make_cookies_info (https, service))
        ?progress ?upload_progress ?override_mime_type
        uri post_params Eliom_request.string_result in
  match content with
  | None -> raise_lwt (Eliom_request.Failed_request 204)
  | Some content -> Lwt.return (uri, content)

let call_service
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?nl_params ?keep_get_na_params
    ?progress ?upload_progress ?override_mime_type
    get_params post_params =
  lwt _, content =
    raw_call_service
      ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
      ?keep_nl_params ?nl_params ?keep_get_na_params
      ?progress ?upload_progress ?override_mime_type
      get_params post_params in
  Lwt.return content


(* == Leave an application. *)

let exit_to
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?nl_params ?keep_get_na_params
    get_params post_params =
  (match create_request_
           ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
           ?keep_nl_params ?nl_params ?keep_get_na_params
           get_params post_params
   with
   | `Get uri -> Eliom_request.redirect_get uri
   | `Post (uri, post_params) -> Eliom_request.redirect_post uri post_params
   | `Put (uri, post_params) -> Eliom_request.redirect_put uri post_params
   | `Delete (uri, post_params) ->
     Eliom_request.redirect_delete uri post_params)

let window_open ~window_name ?window_features
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?nl_params ?keep_get_na_params
    get_params =
  match create_request_
          ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
          ?keep_nl_params ?nl_params ?keep_get_na_params
          get_params ()
  with
  | `Get uri ->
    Dom_html.window##open_(Js.string uri, window_name,
                           Js.Opt.option window_features)
  | `Post (uri, post_params) -> assert false
  | `Put (uri, post_params) -> assert false
  | `Delete (uri, post_params) -> assert false


(* == Call caml service.

   Unwrap the data and execute the associated onload event
   handlers.
*)

let unwrap_caml_content content =
  let r : 'a Eliom_client_common.eliom_caml_service_data =
    Eliom_unwrap.unwrap (Url.decode content) 0
  in
  Lwt.return (r.Eliom_client_common.ecs_data,
              r.Eliom_client_common.ecs_request_data)

let call_ocaml_service
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?nl_params ?keep_get_na_params
    ?progress ?upload_progress ?override_mime_type
    get_params post_params =
  Lwt_log.ign_debug ~section "Call OCaml service";
  lwt _, content =
    raw_call_service
      ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
      ?keep_nl_params ?nl_params ?keep_get_na_params
      ?progress ?upload_progress ?override_mime_type
      get_params post_params in
  lwt () = Lwt_mutex.lock load_mutex in
  Eliom_client0.set_loading_phase ();
  lwt content, request_data = unwrap_caml_content content in
  do_request_data request_data;
  reset_request_nodes ();
  Lwt_mutex.unlock load_mutex;
  run_callbacks (flush_onload () @ [broadcast_load_end]);
  match content with
  | `Success result -> Lwt.return result
  | `Failure msg -> Lwt.fail (Eliom_client_common.Exception_on_server msg)

(* == Function [change_url_string] changes the URL, without doing a request.

   It uses the History API if present, otherwise we write the new URL
   in the fragment part of the URL (see 'redirection_script' in
   'server/eliom_registration.ml'). *)

let current_pseudo_fragment = ref ""
let url_fragment_prefix = "!"
let url_fragment_prefix_with_sharp = "#!"

let change_url_string uri =
  current_uri := fst (Url.split_fragment uri);
  if Eliom_process.history_api
  then begin
    update_state();
    current_state_id := random_int ();
    Dom_html.window##history##pushState(Js.Opt.return (!current_state_id),
                                        Js.string "",
                                        Js.Opt.return (Js.string uri));
    Eliommod_dom.touch_base ();
  end else begin
    current_pseudo_fragment := url_fragment_prefix_with_sharp^uri;
    Eliom_request_info.set_current_path uri;
    if uri <> fst (Url.split_fragment Url.Current.as_string)
    then Dom_html.window##location##hash <- Js.string (url_fragment_prefix^uri)
  end



(* == Function [change_url] changes the URL, without doing a request.
   It takes a GET (co-)service as parameter and its parameters.
 *)

let change_url
    ?absolute
    ?absolute_path
    ?https
    ~service
    ?hostname
    ?port
    ?fragment
    ?keep_nl_params
    ?nl_params
    params =
  change_url_string
    (Eliom_uri.make_string_uri
       ?absolute
       ?absolute_path
       ?https
       ~service
       ?hostname
       ?port
       ?fragment
       ?keep_nl_params
       ?nl_params params)


(***)
let set_template_content ?uri ?fragment =
  let really_set content () =
    (match uri, fragment with
     | Some uri, None -> change_url_string uri
     | Some uri, Some fragment ->
       change_url_string (uri ^ "#" ^ fragment)
     | _ -> ());
    lwt () = Lwt_mutex.lock load_mutex in
    lwt (), request_data = unwrap_caml_content content in
    do_request_data request_data;
    reset_request_nodes ();
    Lwt_mutex.unlock load_mutex;
    run_callbacks (flush_onload ());
    Lwt.return ()
  and cancel () = Lwt.return () in
  function
  | None ->
    Lwt.return ()
  | Some content ->
    run_onunload_wrapper (really_set content) cancel

let set_uri ?fragment uri =
  (* Changing url: *)
  match fragment with
  | None -> change_url_string uri
  | Some fragment -> change_url_string (uri ^ "#" ^ fragment)

(* Function to be called for client side services: *)
let set_content_local ?offset ?fragment new_page =
  let locked = ref true in
  let recover () =
    if !locked then Lwt_mutex.unlock load_mutex;
    if !Eliom_config.debug_timings then
      Firebug.console##timeEnd(Js.string "set_content_local")
  and really_set () =
    (* Inline CSS in the header to avoid the "flashing effect".
       Otherwise, the browser start to display the page before
       loading the CSS. *)
    let preloaded_css = Eliommod_dom.preload_css new_page in
    (* Wait for CSS to be inlined before substituting global nodes: *)
    lwt () = preloaded_css in
    (* Really change page contents *)
    if !Eliom_config.debug_timings
    then Firebug.console##time(Js.string "replace_page");
    (* We insert <base> in the page.
       The URLs of all other pages will be computed w.r.t.
       the base URL. *)
    insert_base new_page;
    Dom.replaceChild Dom_html.document
      new_page
      Dom_html.document##documentElement;
    if !Eliom_config.debug_timings
    then Firebug.console##timeEnd(Js.string "replace_page");
    Eliommod_dom.add_formdata_hack_onclick_handler ();
    locked := false;
    Lwt_mutex.unlock load_mutex;
    run_callbacks (flush_onload () @ [broadcast_load_end]);
    scroll_to_fragment ?offset fragment;
    if !Eliom_config.debug_timings
    then Firebug.console##timeEnd(Js.string "set_content_local");
    Lwt.return ()
  in
  let cancel () = recover (); Lwt.return () in
  try_lwt
    lwt () = Lwt_mutex.lock load_mutex in
    set_loading_phase ();
    if !Eliom_config.debug_timings
    then Firebug.console##time(Js.string "set_content_local");
    run_onunload_wrapper really_set cancel
  with exn ->
    recover ();
    Lwt_log.ign_debug ~section ~exn "set_content_local";
    raise_lwt exn

(* Function to be called for server side services: *)
let set_content ?uri ?offset ?fragment content =
  Lwt_log.ign_debug ~section "Set content";
  match content with
  | None -> Lwt.return ()
  | Some content ->
    let locked = ref true in
    let really_set () =
      Eliom_lib.Option.iter (set_uri ?fragment) uri;
      (* Convert the DOM nodes from XML elements to HTML elements. *)
      let fake_page =
        Eliommod_dom.html_document content registered_process_node
      in
      (* insert_base fake_page; Now done server side *)
      (* Inline CSS in the header to avoid the "flashing effect".
         Otherwise, the browser start to display the page before
         loading the CSS. *)
      let preloaded_css = Eliommod_dom.preload_css fake_page in
      (* Unique nodes of scope request must be bound before the
         unmarshalling/unwrapping of page data. *)
      relink_request_nodes fake_page;
      (* Put the loaded data script in action *)
      load_data_script fake_page;
      (* Unmarshall page data. *)
      let cookies = Eliom_request_info.get_request_cookies () in
      let js_data = Eliom_request_info.get_request_data () in
      (* Update tab-cookies: *)
      let host =
        match uri with
        | None -> None
        | Some uri ->
          match Url.url_of_string uri with
          | Some (Url.Http url)
          | Some (Url.Https url) -> Some url.Url.hu_host
          | _ -> None in
      Eliommod_cookies.update_cookie_table host cookies;
      (* Wait for CSS to be inlined before substituting global nodes: *)
      lwt () = preloaded_css in
      (* Bind unique node (request and global) and register event
         handler.  Relinking closure nodes must take place after
         initializing the client values *)
      let closure_nodeList, attrib_nodeList =
        relink_page_but_client_values fake_page
      in
      Eliom_request_info.set_session_info js_data.Eliom_common.ejs_sess_info;
      (* Really change page contents *)
      if !Eliom_config.debug_timings
      then Firebug.console##time(Js.string "replace_page");
      Lwt_log.ign_debug ~section "Replace page";
      Dom.replaceChild Dom_html.document
        fake_page
        Dom_html.document##documentElement;
      if !Eliom_config.debug_timings
      then Firebug.console##timeEnd(Js.string "replace_page");
      (* Initialize and provide client values. May need to access to
         new DOM. Necessary for relinking closure nodes *)
      do_request_data js_data.Eliom_common.ejs_request_data;
      (* Replace closure ids in document with event handlers
         (from client values) *)
      let () = relink_attribs
          Dom_html.document##documentElement
          js_data.Eliom_common.ejs_client_attrib_table attrib_nodeList in
      let onload_closure_nodes =
        relink_closure_nodes
          Dom_html.document##documentElement
          js_data.Eliom_common.ejs_event_handler_table closure_nodeList
      in
      (* The request node table must be empty when nodes received via
         call_ocaml_service are unwrapped. *)
      reset_request_nodes ();
      Eliommod_dom.add_formdata_hack_onclick_handler ();
      locked := false;
      Lwt_mutex.unlock load_mutex;
      run_callbacks
        (flush_onload () @ [onload_closure_nodes; broadcast_load_end]);
      scroll_to_fragment ?offset fragment;
      if !Eliom_config.debug_timings then
        Firebug.console##timeEnd(Js.string "set_content");
      Lwt.return ()
    and recover () =
      if !locked then Lwt_mutex.unlock load_mutex;
      if !Eliom_config.debug_timings
      then Firebug.console##timeEnd(Js.string "set_content")
    in
    try_lwt
      lwt () = Lwt_mutex.lock load_mutex in
      set_loading_phase ();
      if !Eliom_config.debug_timings
      then Firebug.console##time(Js.string "set_content");
      let g () = recover (); Lwt.return () in
      run_onunload_wrapper really_set g
    with exn ->
      recover ();
      Lwt_log.ign_debug ~section ~exn "set_content";
      raise_lwt exn



let reload_function = ref None

(* == Main (exported) function: change the content of the page without
   leaving the javascript application. See [change_page_uri] for the
   function used to change page when clicking a link and
   [change_page_{get,post}_form] when submiting a form. *)

let change_page
    ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
    ?keep_nl_params ?(nl_params = Eliom_parameter.empty_nl_params_set)
    ?keep_get_na_params
    ?progress ?upload_progress ?override_mime_type
    get_params post_params =
  Lwt_log.ign_debug ~section "Change page";
  let xhr = Eliom_service.xhr_with_cookies service in
  if xhr = None
  || (https = Some true && not Eliom_request_info.ssl_)
  || (https = Some false && Eliom_request_info.ssl_)
  then
    Lwt.return
      (exit_to
         ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
         ?keep_nl_params ~nl_params ?keep_get_na_params
         get_params post_params)
  else
    with_progress_cursor
      (match xhr with
       | Some (Some tmpl as t)
         when t = Eliom_request_info.get_request_template () ->
         let nl_params =
           Eliom_parameter.add_nl_parameter
             nl_params Eliom_request.nl_template tmpl
         in
         lwt uri, content =
           raw_call_service
             ?absolute ?absolute_path ?https ~service ?hostname ?port ?fragment
             ?keep_nl_params ~nl_params ?keep_get_na_params
             ?progress ?upload_progress ?override_mime_type
             get_params post_params in
         set_template_content ~uri ?fragment (Some content)
       | _ ->
         match Eliom_service.get_client_fun_ service () with
         | Some f ->
           (* The service has a client side implementation.
              We do not make the request *)
           (* I record the function to be used for void coservices: *)
           Eliom_lib.Option.iter
             (fun rf ->
                reload_function := Some (fun () () -> rf get_params ()))
             (Eliom_service.get_reload_fun service);
           lwt () = f get_params post_params in
           let uri =
             match
               create_request_
                 ?absolute ?absolute_path ?https ~service ?hostname ?port
                 ?fragment ?keep_nl_params ~nl_params ?keep_get_na_params
                 get_params post_params
             with
             | `Get uri
             | `Post (uri, _)
             | `Put (uri, _)
             | `Delete (uri, _) -> uri
           in
           let uri, fragment = Url.split_fragment uri in
           set_uri uri;
           Lwt.return ()
         | None ->
           (* No client-side implementation *)
           reload_function := None;
           let cookies_info = Eliom_uri.make_cookies_info (https, service) in
           lwt (uri, content) =
             match
               create_request_
                 ?absolute ?absolute_path ?https ~service ?hostname ?port
                 ?fragment ?keep_nl_params ~nl_params ?keep_get_na_params
                 get_params post_params
             with
             | `Get uri ->
               Eliom_request.http_get
                 ~expecting_process_page:true ?cookies_info uri []
                 Eliom_request.xml_result
             | `Post (uri, p) ->
               Eliom_request.http_post
                 ~expecting_process_page:true ?cookies_info uri p
                 Eliom_request.xml_result
             | `Put (uri, p) ->
               Eliom_request.http_put
                 ~expecting_process_page:true ?cookies_info uri p
                 Eliom_request.xml_result
             | `Delete (uri, p) ->
               Eliom_request.http_delete
                 ~expecting_process_page:true ?cookies_info uri p
                 Eliom_request.xml_result
           in
           let uri, fragment = Url.split_fragment uri in
           set_content ~uri ?fragment content)

(* Function used in "onclick" event handler of <a>.  *)

let change_page_uri ?cookies_info ?tmpl ?(get_params = []) full_uri =
  Lwt_log.ign_debug ~section "Change page uri";
  with_progress_cursor
    (let uri, fragment = Url.split_fragment full_uri in
     if uri <> !current_uri || fragment = None
     then begin
       match tmpl with
       | Some t when tmpl = Eliom_request_info.get_request_template () ->
         lwt (uri, content) = Eliom_request.http_get
             ?cookies_info uri
             ((Eliom_request.nl_template_string, t) :: get_params)
             Eliom_request.string_result
         in
         set_template_content ~uri ?fragment content
       | _ ->
         lwt (uri, content) = Eliom_request.http_get
             ~expecting_process_page:true ?cookies_info uri get_params
             Eliom_request.xml_result
         in
         set_content ~uri ?fragment content
     end else begin
       change_url_string full_uri;
       scroll_to_fragment fragment;
       Lwt.return ()
     end)

(* Functions used in "onsubmit" event handler of <form>.  *)

let change_page_get_form ?cookies_info ?tmpl form full_uri =
  with_progress_cursor
    (let form = Js.Unsafe.coerce form in
     let uri, fragment = Url.split_fragment full_uri in
     match tmpl with
     | Some t when tmpl = Eliom_request_info.get_request_template () ->
       lwt uri, content = Eliom_request.send_get_form
           ~get_args:[Eliom_request.nl_template_string, t]
           ?cookies_info form uri
           Eliom_request.string_result
       in
       set_template_content ~uri ?fragment content
     | _ ->
       lwt uri, content = Eliom_request.send_get_form
           ~expecting_process_page:true ?cookies_info form uri
           Eliom_request.xml_result
       in
       set_content ~uri ?fragment content )

let change_page_post_form ?cookies_info ?tmpl form full_uri =
  with_progress_cursor
    (let form = Js.Unsafe.coerce form in
     let uri, fragment = Url.split_fragment full_uri in
     match tmpl with
     | Some t when tmpl = Eliom_request_info.get_request_template () ->
       lwt uri, content = Eliom_request.send_post_form
           ~get_args:[Eliom_request.nl_template_string, t]
           ?cookies_info form uri
           Eliom_request.string_result
       in
       set_template_content ~uri ?fragment content
     | _ ->
       lwt uri, content = Eliom_request.send_post_form
           ~expecting_process_page:true ?cookies_info form uri
           Eliom_request.xml_result
       in
       set_content ~uri ?fragment content )

let _ =
  change_page_uri_ :=
    (fun ?cookies_info ?tmpl href ->
       Lwt.ignore_result (change_page_uri ?cookies_info ?tmpl href));
  change_page_get_form_ :=
    (fun ?cookies_info ?tmpl form href ->
       Lwt.ignore_result (change_page_get_form ?cookies_info ?tmpl form href));
  change_page_post_form_ :=
    (fun ?cookies_info ?tmpl form href ->
       Lwt.ignore_result (change_page_post_form ?cookies_info ?tmpl form href))

(* == Main (internal) function: change the content of the page without leaving
      the javascript application. *)




(* == Navigating through the history... *)

let () =

  if Eliom_process.history_api
  then

    let goto_uri full_uri state_id =
      current_state_id := state_id;
      let state = get_state state_id in
      let tmpl = (if state.template = Js.string ""
                  then None
                  else Some (Js.to_string state.template))
      in
      Lwt.ignore_result
        (with_progress_cursor
           (let uri, fragment = Url.split_fragment full_uri in
            if uri <> !current_uri
            then begin
              current_uri := uri;
              match tmpl with
              | Some t
                when tmpl = Eliom_request_info.get_request_template () ->
                lwt (uri, content) = Eliom_request.http_get
                    uri [(Eliom_request.nl_template_string, t)]
                    Eliom_request.string_result
                in
                set_template_content content >>
                (scroll_to_fragment ~offset:state.position fragment;
                 Lwt.return ())
              | _ ->
                lwt uri, content =
                  Eliom_request.http_get ~expecting_process_page:true uri []
                    Eliom_request.xml_result in
                set_content ~offset:state.position ?fragment content
            end else
              (scroll_to_fragment ~offset:state.position fragment;
               Lwt.return ())))
    in

    let goto_uri full_uri state_id =
      (* CHECKME: is it OK that set_state happens after the unload
         callbacks are executed? *)
      let f () = update_state (); goto_uri full_uri state_id
      and g () = () in
      run_onunload_wrapper f g

    in

    Lwt.ignore_result
      (lwt () = wait_load_end () in
       Dom_html.window##history##replaceState(
         Js.Opt.return !current_state_id,
         Js.string "",
         Js.some Dom_html.window##location##href );
       Lwt.return ());

    Dom_html.window##onpopstate <-
      Dom_html.handler (fun event ->
        let full_uri = Js.to_string Dom_html.window##location##href in
        Eliommod_dom.touch_base ();
        Js.Opt.case ((Js.Unsafe.coerce event)##state : int Js.opt)
          (fun () -> () (* Ignore dummy popstate event fired by chromium. *))
          (goto_uri full_uri);
        Js._false)

  else (* Without history API *)

    (* FIXME: This should be adapted to work with template...
       Solution: add the "state_id" in the fragment ??
    *)

    let read_fragment () = Js.to_string Dom_html.window##location##hash in
    let auto_change_page fragment =
      Lwt.ignore_result
        (let l = String.length fragment in
         if (l = 0) || ((l > 1) && (fragment.[1] = '!'))
         then if fragment <> !current_pseudo_fragment then
             (current_pseudo_fragment := fragment;
              let uri =
                match l with
                | 2 -> "./" (* fix for firefox *)
                | 0 | 1 -> fst (Url.split_fragment Url.Current.as_string)
                | _ -> String.sub fragment 2 ((String.length fragment) - 2)
              in
              (* CCC TODO handle templates *)
              change_page_uri uri)
           else Lwt.return ()
         else Lwt.return ())
    in

    Eliommod_dom.onhashchange (fun s -> auto_change_page (Js.to_string s));
    let first_fragment = read_fragment () in
    if first_fragment <> !current_pseudo_fragment
    then
      Lwt.ignore_result (
        lwt () = wait_load_end () in
        auto_change_page first_fragment;
        Lwt.return ())


let server_function
    ?scope ?options ?charset ?code ?content_type ?headers ?secure_session ~name
    ?csrf_safe ?csrf_scope ?csrf_secure ?max_use ?timeout ?https ?error_handler
    argument_type () =
  let service =
    Eliom_service.Ocaml.post_coservice'
      ~name
      ?csrf_safe ?csrf_scope ?csrf_secure ?max_use ?timeout ?https
      ~post_params:Eliom_parameter.(ocaml "argument" argument_type)
      ()
  in
  fun a -> call_ocaml_service ~absolute:true ~service () a

let () =
  Eliom_unwrap.register_unwrapper
    (Eliom_unwrap.id_of_int Eliom_common_base.server_function_unwrap_id_int)
    (fun (service, _) ->
       (* 2013-07-31 I make all RPC's absolute because otherwise
          it does not work with mobile apps.
          Is it a problem?
          -- Vincent *)
       call_ocaml_service ~absolute:true ~service ())

let get_application_name = Eliom_process.get_application_name
