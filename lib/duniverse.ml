open Import
open Sexplib.Conv
module O = Opam

type unresolved = Git.Ref.t

type resolved = Git.Ref.resolved [@@deriving sexp]

module Deps = struct
  module Opam = struct
    type t = { name : string; version : string } [@@deriving sexp]

    let equal t t' =
      let { name; version } = t in
      let { name = name'; version = version' } = t' in
      String.equal name name' && String.equal version version'

    let pp fmt { name; version } = Format.fprintf fmt "%s.%s" name version

    let raw_pp fmt { name; version } =
      let open Pp_combinators.Ocaml in
      Format.fprintf fmt "@[<hov 2>{ name = %a;@ version = %a }@]" string name string version

    let to_opam_dep t : OpamTypes.filtered_formula =
      let name = OpamPackage.Name.of_string t.name in
      Atom (name, Atom (Constraint (`Eq, FString t.version)))
  end

  module Source = struct
    module Url = struct
      type 'ref t = Git of { repo : string; ref : 'ref } | Other of string [@@deriving sexp]

      let equal equal_ref t t' =
        match (t, t') with
        | Git { repo; ref }, Git { repo = repo'; ref = ref' } ->
            String.equal repo repo' && equal_ref ref ref'
        | Other s, Other s' -> String.equal s s'
        | _ -> false

      let pp pp_ref fmt t =
        let open Pp_combinators.Ocaml in
        match t with
        | Git { repo; ref } ->
            Format.fprintf fmt "@[<hov 2>Git@ @[<hov 2>{ repo = %a;@ ref = %a }@]@]" string repo
              pp_ref ref
        | Other s -> Format.fprintf fmt "@[<hov 2>Other@ %a@]" string s

      let opam_url_from_string s = OpamUrl.parse ~from_file:true ~handle_suffix:false s

      let to_string : resolved t -> string = function
        | Other s -> s
        | Git { repo; ref = { Git.Ref.commit; _ } } -> Printf.sprintf "%s#%s" repo commit

      let to_opam_url t = opam_url_from_string (to_string t)
    end

    module Package = struct
      type t = { opam : Opam.t; dev_repo : string; url : unresolved Url.t }

      let equal t t' =
        Opam.equal t.opam t'.opam
        && String.equal t.dev_repo t'.dev_repo
        && Url.equal Git.Ref.equal t.url t'.url

      let pp fmt { opam; dev_repo; url } =
        Format.fprintf fmt "@[<hov 2>{ opam = %a;@ upstream = %S;@ ref = %a }@]" Opam.raw_pp opam
          dev_repo (Url.pp Git.Ref.pp) url

      let from_package_summary ~get_default_branch ps =
        let open O.Package_summary in
        let open Result.O in
        let url ourl =
          match (ourl : O.Url.t) with
          | Other s -> Ok (Url.Other s)
          | Git { repo; ref = Some ref } -> Ok (Url.Git { repo; ref })
          | Git { repo; ref = None } ->
              get_default_branch repo >>= fun ref -> Ok (Url.Git { repo; ref })
        in
        match ps with
        | _ when is_base_package ps -> Ok None
        | { url_src = None; _ } | { dev_repo = None; _ } -> Ok None
        | { url_src = Some url_src; name; version; dev_repo = Some dev_repo } ->
            url url_src >>= fun url -> Ok (Some { opam = { name; version }; dev_repo; url })
    end

    type 'ref t = {
      dir : string;
      version : string;
      dev_repo : string;
      url : 'ref Url.t;
      provided_packages : Opam.t list; [@default []] [@sexp_drop_default.sexp]
    }
    [@@deriving sexp]

    let equal equal_ref t t' =
      let { dir; version; dev_repo; url; provided_packages } = t in
      let {
        dir = dir';
        version = version';
        dev_repo = dev_repo';
        url = url';
        provided_packages = provided_packages';
      } =
        t'
      in
      String.equal dir dir' && String.equal version version' && String.equal dev_repo dev_repo'
      && Url.equal equal_ref url url'
      && List.equal Opam.equal provided_packages provided_packages'

    let raw_pp pp_ref fmt { dir; version; dev_repo; url; provided_packages } =
      let open Pp_combinators.Ocaml in
      Format.fprintf fmt
        "@[<hov 2>{ dir = %a;@ version = %a;@ dev_repo = %a;@ ref = %a;@ provided_packages = %a }@]"
        string dir string version string dev_repo (Url.pp pp_ref) url (list Opam.raw_pp)
        provided_packages

    let dir_name_from_package { Opam.name; version } = Printf.sprintf "%s.%s" name version

    let from_package { Package.opam; dev_repo; url } =
      let dir = dir_name_from_package opam in
      { dir; version = opam.version; dev_repo; url; provided_packages = [ opam ] }

    let aggregate t package =
      let package_name = package.Package.opam.name in
      let new_dir =
        match Ordering.of_int (String.compare t.dir package_name) with
        | Lt | Eq -> t.dir
        | Gt -> dir_name_from_package package.Package.opam
      in
      let new_url, new_version =
        match Ordering.of_int (OpamVersionCompare.compare t.version package.opam.version) with
        | Gt | Eq -> (t.url, t.version)
        | Lt -> (package.url, package.opam.version)
      in
      {
        t with
        dir = new_dir;
        version = new_version;
        url = new_url;
        provided_packages = package.opam :: t.provided_packages;
      }

    let aggregate_packages l =
      let update map ({ Package.dev_repo; _ } as package) =
        String.Map.update map dev_repo ~f:(function
          | None -> Some (from_package package)
          | Some t -> Some (aggregate t package))
      in
      let aggregated_map = List.fold_left ~init:String.Map.empty ~f:update l in
      String.Map.values aggregated_map

    let resolve ~resolve_ref ({ url; _ } as t) =
      let open Result.O in
      match (url : unresolved Url.t) with
      | Git { repo; ref } ->
          resolve_ref ~repo ~ref >>= fun resolved_ref ->
          let resolved_url = Url.Git { repo; ref = resolved_ref } in
          Ok { t with url = resolved_url }
      | Other s -> Ok { t with url = Other s }

    let to_opam_pin_deps (t : resolved t) =
      let url = Url.to_opam_url t.url in
      List.map t.provided_packages ~f:(fun { Opam.name; version } ->
          let opam_pkg = OpamPackage.of_string (Printf.sprintf "%s.%s" name version) in
          (opam_pkg, url))
  end

  type 'ref t = 'ref Source.t list [@@deriving sexp]

  let equal equal_ref t t' = List.equal (Source.equal equal_ref) t t'

  let raw_pp pp_ref fmt t =
    let open Pp_combinators.Ocaml in
    (list (Source.raw_pp pp_ref)) fmt t

  let from_package_summaries ~get_default_branch summaries =
    let open Result.O in
    let results = List.map ~f:(Source.Package.from_package_summary ~get_default_branch) summaries in
    Result.List.all results >>= fun pkg_opts ->
    let pkgs = List.filter_opt pkg_opts in
    Ok (Source.aggregate_packages pkgs)

  let resolve ~resolve_ref t = Parallel.map ~f:(Source.resolve ~resolve_ref) t |> Result.List.all
end

module Config = struct
  type t = { version : string; root_packages : Types.Opam.package list }
  [@@deriving sexp] [@@sexp.allow_extra_fields]
end

type t = { config : Config.t; deps : resolved Deps.t } [@@deriving sexp]

let load_dune_get ~file = Persist.load_sexp "duniverse" t_of_sexp file

let sort ({ deps; _ } as t) =
  let sorted_deps =
    let open Deps.Source in
    let cmp source source' = String.compare source.dir source'.dir in
    List.sort ~cmp deps
  in
  { t with deps = sorted_deps }

let sexp_of_duniverse duniverse =
  Sexplib0.Sexp_conv.sexp_of_list (Deps.Source.sexp_of_t Git.Ref.sexp_of_resolved) duniverse

let duniverse_of_sexp sexp =
  Sexplib0.Sexp_conv.list_of_sexp (Deps.Source.t_of_sexp Git.Ref.resolved_of_sexp) sexp

module Opam_ext : sig
  type 'a field

  val duniverse_field : Git.Ref.resolved Deps.Source.t list field

  val config_field : Config.t field

  val add : ('a -> Sexplib0.Sexp.t) -> 'a field -> 'a -> OpamFile.OPAM.t -> OpamFile.OPAM.t

  val get :
    ?file:string ->
    ?default:'a ->
    (Sexplib0.Sexp.t -> 'a) ->
    'a field ->
    OpamFile.OPAM.t ->
    ('a, [> `Msg of string ]) result
end = struct
  type _ field = string

  let duniverse_field = "x-duniverse-duniverse"

  let config_field = "x-duniverse-config"

  let add sexp_of field a opam =
    OpamFile.OPAM.add_extension opam field (Opam_value.from_sexp (sexp_of a))

  let get ?file ?default of_sexp field opam =
    let open Result.O in
    match (OpamFile.OPAM.extended opam field (fun i -> i), default) with
    | None, Some default -> Ok default
    | None, None ->
        let file_suffix_opt = Option.map ~f:(Printf.sprintf " in %s") file in
        let file_suffix = Option.value ~default:"" file_suffix_opt in
        Error (`Msg (Printf.sprintf "Missing %s field%s" field file_suffix))
    | Some ov, _ -> Opam_value.to_sexp_strict ov >>| of_sexp
end

let to_opam (t : t) =
  let deps =
    let packages =
      let open Deps.Source in
      let source = List.concat_map t.deps ~f:(fun s -> s.provided_packages) in
      let open Deps.Opam in
      List.sort ~cmp:(fun o o' -> String.compare o.name o'.name) source
    in
    match packages with
    | hd :: tl ->
        List.fold_left tl
          ~f:(fun acc pkg -> OpamFormula.(And (acc, Deps.Opam.to_opam_dep pkg)))
          ~init:(Deps.Opam.to_opam_dep hd)
    | [] -> OpamFormula.Empty
  in
  let pin_deps =
    List.concat_map t.deps ~f:Deps.Source.to_opam_pin_deps
    |> List.sort ~cmp:(fun (p, _) (p', _) -> OpamPackage.compare p p')
  in
  let t = sort t in
  let open OpamFile.OPAM in
  empty
  |> with_maintainer [ "duniverse" ]
  |> with_synopsis "duniverse generated lockfile"
  |> with_depends deps |> with_pin_depends pin_deps
  |> Opam_ext.(add Config.sexp_of_t config_field t.config)
  |> Opam_ext.(add sexp_of_duniverse duniverse_field t.deps)

let from_opam ?file opam =
  let open Result.O in
  Opam_ext.(get ?file Config.t_of_sexp config_field opam) >>= fun config ->
  Opam_ext.(get ?file ~default:[] duniverse_of_sexp duniverse_field opam) >>= fun duniverse ->
  let deps = duniverse in
  Ok { config; deps }

let save ~file t =
  let open Result.O in
  let opam = to_opam t in
  Bos.OS.File.with_oc file
    (fun oc () ->
      OpamFile.OPAM.write_to_channel oc opam;
      Ok ())
    ()
  >>= fun res -> res

let load ~file =
  let open Result.O in
  let filename = Fpath.to_string file in
  Bos.OS.File.with_ic file
    (fun ic () ->
      let filename = OpamFile.make (OpamFilename.of_string filename) in
      OpamFile.OPAM.read_from_channel ~filename ic)
    ()
  >>= fun opam -> from_opam ~file:filename opam
