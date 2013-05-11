(**
   An interface to program state files generated by Tracecap. 
   
   @author Juan Caballero, Zhenkai Liang
*)

open Vine

module D = Debug.Make(struct let name="temu_state" and default=`NoDebug end)
module String = ExtString.String
module List = ExtList.List

exception Unknown_state_version
exception Incomplete_value
exception Registers_unavailable

(* Convert an unsigned 32-bit interger into a 64-bit one *)
let int64_of_uint32 x =
  Int64.logand
    (Int64.of_int32 x)
    0x00000000ffffffffL

(* Magic number for state files *)
let sMAGIC_NUMBER = 0xFFFEFFFEl

(* Page size *)
let default_page_size = 4096L

(* Get the start address of the memory page containing the given address *)
let page_start ?(page_size=default_page_size) addr =
  Int64.mul (Int64.div addr page_size) page_size

(* Get the end of the memory page that contains the given address *)
let page_end ?(page_size=default_page_size) addr =
  Int64.add (page_start addr) (Int64.pred page_size)

(* Masks for flags *)
let state_registers_mask = 0x1
let state_kernel_mem_mask = 0x2
let state_taint_mask = 0x4
let state_virtual_addr_mask = 0x8
let state_process_snapshot_mask = 0x10

(* Flags *)
type state_flags_t = {
  includes_registers : bool;
  includes_kernel_mem : bool;
  includes_taint : bool;
  virtual_addresses : bool;
  process_snapshot : bool;
}

(* The state file header *)
type state_header_t = {
  state_version : int;
  state_word_size : int;
  state_flags : state_flags_t;
}

(* Taint region covering taint_block_size bytes *)
type taint_region_t = {
  tr_start_addr : Libasmir.address_t;
  tr_taintmask : int64;
  tr_pos : int64;
}

type userRegs = {
  eax : int32; 
  ebx : int32; 
  ecx : int32; 
  edx : int32; 
  esi : int32; 
  edi : int32; 
  ebp : int32; 
  esp : int32; 
  eip : int32;
  eflags : int32; 
  xcs : int32; 
  xds : int32; 
  xes : int32; 
  xfs : int32;
  xgs : int32; 
  xss : int32; 
}

(** Class for memory blocks *)
class virtual memblock =
object
  method virtual first : Int64.t
  method virtual last : Int64.t
  method virtual size : int
  method virtual file_pos : Int64.t
  method virtual taint_l : taint_region_t list
  method virtual taint_block_size : int
  method virtual num_taint_blocks : int
  method virtual num_tainted_bytes : int

  method virtual unserialize : state_flags_t -> in_channel -> IO.input -> unit
  method virtual serialize : unit IO.output -> string -> unit
end

(* A map of memory blocks *)
module BlockMap = 
  Map.Make (
    struct 
      type t = int64 
      let compare = compare
    end
  )

(** Class for state interface *)
class state_interface header channel io_channel regs_opt 
        (block_l : memblock list) =
  let process_block (acc_t,acc_c) b =
    BlockMap.add b#first b acc_t,acc_c+1 
  in
  let (bmap,cnt) = 
    List.fold_left process_block (BlockMap.empty,0) block_l 
  in
object(self)
  val _header : state_header_t = header
  val _rawchannel : in_channel = channel
  val _iochannel : IO.input = io_channel
  val _curr_offset : int64 = LargeFile.pos_in channel
  val _regs_opt : userRegs option = regs_opt 
  val _num_blocks = cnt

  (* Block Map *)
  val _block_map = bmap

  (* Return the header version *)
  method version = _header.state_version

  (* Return the header flags *)
  method flags = _header.state_flags

  (* Return the list of blocks in the state file *)
  method blocks = 
    let l = BlockMap.fold (fun _ b acc -> b :: acc) _block_map [] in
    List.rev l

  (* Return the number of blocks in the state file *)
  method num_blocks = _num_blocks

  (* Return the register structure *)
  method regs = 
    match _regs_opt with
      | Some(regs) -> regs
      | None -> raise Registers_unavailable

  (* Return the channel *)
  method private channel = _rawchannel

  (* Return the IO channel *)
  method private iochannel = _iochannel

  (* Return the current file offset *)
  method private current_offset () = LargeFile.pos_in _rawchannel

  (* Cleanup *)
  method cleanup =
    IO.close_in _iochannel;
    close_in_noerr _rawchannel;

  (* Returns true if the given address exists in the state file *)
  method exists addr =
    BlockMap.mem (page_start addr) _block_map

  (* Obtain values from memory block (reads from file) *)
  method get_memrange first last =
    let process_block _ blk acc =
      let block_overlaps = not ((blk#last < first) || (blk#first > last)) in
      if block_overlaps then (
        (* Get first address *)
        let first_addr =
          if (first < blk#first)
            then blk#first
            else first
        in
        (* Get last address *)
        let last_addr =
          if (last > blk#last)
            then blk#last
            else last
        in
        (* Get file position to start reading *)
        let first_pos =
          let offset = Int64.sub first_addr blk#first in
          Int64.add blk#file_pos offset
        in
        (* Get size to read *)
        let size= 
          Int64.to_int (Int64.succ (Int64.sub last_addr first_addr)) 
        in
        (* Position file pointer *)
        let () = LargeFile.seek_in _rawchannel first_pos in
        (* Read data as string *)
        let blk_str = IO.nread _iochannel size in
        (* Add each byte to accumulator *)
        let process_char (acc2,idx) c =
          let addr = Int64.add first_addr idx in
          (addr,c) :: acc2, Int64.succ idx
        in
        fst (String.fold_left process_char (acc,0L) blk_str)
      )
      else acc
    in
    let l = BlockMap.fold process_block _block_map [] in
    List.rev l

  (* Get byte value at given address *)
  method get_char addr =
    try snd (List.hd (self#get_memrange addr addr))
    with _ -> raise Incomplete_value

  (* Get byte value at given address *)
  method get_byte addr = 
    try Char.code (snd (List.hd (self#get_memrange addr addr)))
    with _ -> raise Incomplete_value

  (* Get short (16-bit) value at given address *)
  method get_short ?(big_endian=false) (addr : Libasmir.address_t) = 
    let pair_l = self#get_memrange addr (Int64.succ addr) in
    let val_l = 
      if big_endian 
        then List.map (fun (a,c) -> int_of_char c) (List.rev pair_l)
        else List.map (fun (a,c) -> int_of_char c) pair_l
    in
    match val_l with
      | v0 :: v1 :: [] -> (v1 lsl 8) lor v0
      | _ -> raise Incomplete_value

  (* Get word (32-bit) value at given address *)
  method get_word ?(big_endian=false) addr = 
    let pair_l = self#get_memrange addr (Int64.add addr 3L) in
    let val_l =
      if big_endian 
        then 
          List.map (fun (a,c) -> Int32.of_int (int_of_char c)) (List.rev pair_l)
        else 
          List.map (fun (a,c) -> Int32.of_int (int_of_char c)) pair_l
    in
    match val_l with
      | v0 :: v1 :: v2 :: v3 :: [] -> (
          Int32.logor
            (Int32.logor (Int32.shift_left v3 24) (Int32.shift_left v2 16))
            (Int32.logor (Int32.shift_left v1 8) v0)
        )
      | _ -> raise Incomplete_value

  (* Get long (64-bit) value at given address *)
  method get_long ?(big_endian=false) (addr : Libasmir.address_t) = 
    let pair_l = self#get_memrange addr (Int64.add addr 7L) in
    let val_l =
      if big_endian
        then 
          List.map (fun (a,c) -> Int64.of_int (int_of_char c)) (List.rev pair_l)
        else 
          List.map (fun (a,c) -> Int64.of_int (int_of_char c)) pair_l
    in
    match val_l with
      | v0 :: v1 :: v2 :: v3 :: v4 :: v5 :: v6 :: v7 :: [] -> (
          let high_word = 
            Int64.logor
              (Int64.logor (Int64.shift_left v7 56) (Int64.shift_left v6 48))
              (Int64.logor (Int64.shift_left v5 40) (Int64.shift_left v4 32))
          in
          let low_word =
            Int64.logor
              (Int64.logor (Int64.shift_left v3 24) (Int64.shift_left v2 16))
              (Int64.logor (Int64.shift_left v1 8) v0)
          in
          Int64.logor high_word low_word
        ) 
      | _ -> raise Incomplete_value

  (* Get float (32-bit) value at given address *)
  method get_float ?(big_endian=false) (addr : Libasmir.address_t) =
    let val32 = self#get_word ~big_endian:big_endian addr in
    Int32.float_of_bits val32

  (* Get float (32-bit) value at given address *)
  method get_double ?(big_endian=false) (addr : Libasmir.address_t) =
    let val64 = self#get_long ~big_endian:big_endian addr in
    Int64.float_of_bits val64

  (* Get an array of values at given address with given size *)
  method get_array (addr : Libasmir.address_t) size =
    let pair_l = 
      self#get_memrange addr (Int64.add addr (Int64.of_int (size-1)))
    in
    let num_read = List.length pair_l in
    if (num_read = size) then (
      let arr = Array.make size 0 in
      List.iteri (fun idx (_,c) -> arr.(idx) <- Char.code c) pair_l;
      arr
    )
    else raise Incomplete_value

  (* Get an string at given address with given size *)
  method get_string (addr : Libasmir.address_t) size =
    let pair_l = 
      self#get_memrange addr (Int64.add addr (Int64.of_int (size-1)))
    in
    let num_read = List.length pair_l in
    if (num_read = size) then (
      let str = String.create num_read in
      List.iteri (fun idx (_,c) -> str.[idx] <- c) pair_l;
      str
    )
    else raise Incomplete_value

  (* Get a string until a null value is found *)
  method get_ascii_string addr =
    let buf = Buffer.create 4096 in
    let first_block = page_start addr in
    let process_block _ blk found_first =
      let process_block = 
        found_first || ((page_start blk#first) = first_block)
      in
      if process_block then (
        (* Get first address *)
        let first_addr =
          if found_first
            then blk#first
            else addr
        in
        (* Get file position to start reading *)
        let first_pos =
          let offset = Int64.sub first_addr blk#first in
          Int64.add blk#file_pos offset
        in
        (* Get size to read *)
        let size =
          Int64.to_int (Int64.succ (Int64.sub blk#last first_addr))
        in
        (* Position file pointer *)
        let () = LargeFile.seek_in _rawchannel first_pos in
        (* Read data as string *)
        let blk_str = IO.nread _iochannel size in
        (* Find null character *)
        let found_null,str = 
          try (
            let idx = String.index blk_str (Char.chr 0) in
            true, String.sub blk_str 0 idx
          )
          with Not_found -> false,blk_str
        in
        Buffer.add_string buf str;
        if found_null 
          then failwith "Done"
          else true
      )
      else found_first
    in
    let _ = 
      try BlockMap.fold process_block _block_map false
      with _ -> true
    in
    Buffer.contents buf

  (* Get a wide string until a null value is found *)
  method get_wide_string addr =
    let buf = Buffer.create 4096 in
    let first_block = page_start addr in
    let null_char = Char.chr 0 in
    let null_delimiter = String.make 3 null_char in
    let process_block _ blk (found_first,num_null_found) =
      let process_block =
        found_first || ((page_start blk#first) = first_block)
      in
      if process_block then (
        (* Get first address *)
        let first_addr =
          if found_first
            then blk#first
            else addr
        in
        (* Get file position to start reading *)
        let first_pos =
          let offset = Int64.sub first_addr blk#first in
          Int64.add blk#file_pos offset
        in
        (* Get size to read *)
        let size =
          Int64.to_int (Int64.succ (Int64.sub blk#last first_addr))
        in
        (* Position file pointer *)
        let () = LargeFile.seek_in _rawchannel first_pos in
        (* Read data as string *)
        let blk_str = IO.nread _iochannel size in
        (* Find null character *)
        let found_end, null_count, str =
          match num_null_found with
            (* NOTE: These corners cases for when the null terminator may be 
                cut by a page end have not been tested *)
            | 2 when ((size > 0) && (blk_str.[0] = null_char)) -> true,0,""
            | 1 when ((size > 1) && (blk_str.[0] = null_char) && 
                      (blk_str.[1] = null_char)) -> true,0,""
            | _ -> (
                try (
                  let idx = 
                    Str.search_forward (Str.regexp_string null_delimiter) 
                      blk_str 0 
                  in
                  true, 0, String.sub blk_str 0 (idx+1)
                )
                with Not_found -> (
                  let count = 
                    if (blk_str.[size - 1] = null_char)
                      then 1
                      else 0
                  in
                  let count = 
                    if (count > 0) && (blk_str.[size - 2] = null_char)
                      then 2
                      else count
                  in
                  false, count, blk_str
                )
              )
        in
        Buffer.add_string buf str;
        if found_end
          then failwith "Done"
          else true,0
      )
      else found_first,num_null_found
    in
    let _ =
      try BlockMap.fold process_block _block_map (false,0)
      with _ -> true,0
    in
    Buffer.contents buf

  (* Generate range inits from state file *)
  method range_inits ranges memvar =
    List.fold_left
      (fun mem_inits (first,last) ->
         let data = self#get_memrange first last in
         let mem_inits =
           List.fold_left
             (fun mem_inits (addr,byte) ->
                let lhs = Mem(memvar,
                        const_of_int64 addr_t addr,
                        REG_8) in
                let rhs = const_of_int REG_8 (int_of_char byte) in
                Move(lhs,rhs)::mem_inits
             )
             mem_inits
             data
         in
         mem_inits
      )
      []
      ranges

  (* Generate a hashtable (Libasmir.address_t -> char) for all bytes in the
       range. Missing bytes in the state file do not appear in the table. *)
  method private get_memrange_tbl first last =
    (* Create hashtbl *)
    let range_size = 
      Int64.to_int (Int64.succ (Int64.sub last first)) 
    in
    let tbl = Hashtbl.create range_size in
    (* Iterate over all blocks in state file *)
    let process_block _ blk =
      let block_overlaps = not ((blk#last < first) || (blk#first > last)) in
      if block_overlaps then (
        (* Get first address *)
        let first_addr =
          if (first < blk#first)
            then blk#first
            else first
        in
        (* Get last address *)
        let last_addr =
          if (last > blk#last)
            then blk#last
            else last
        in
        (* Get file position to start reading *)
        let first_pos =
          let offset = Int64.sub first_addr blk#first in
          Int64.add blk#file_pos offset
        in
        (* Get size to read *)
        let size =
          Int64.to_int (Int64.succ (Int64.sub last_addr first_addr))
        in
        (* Position file pointer *)
        let () = LargeFile.seek_in _rawchannel first_pos in
        (* Read data as string *)
        let blk_str = IO.nread _iochannel size in
        (* Add each byte to the table *)
        let process_char idx byteval =
          let addr = Int64.add first_addr idx in
          Hashtbl.replace tbl addr byteval;
          Int64.succ idx
        in
        ignore (String.fold_left process_char 0L blk_str)
      )
    in
    BlockMap.iter process_block _block_map;
    tbl

  (* Apply given function to values of all bytes in range. 
      If the range has gaps, the gaps are skipped, so the function 
      is only applied to addresses in the given range that exist 
      in the file *)
  method iter_range (f : (Libasmir.address_t -> char -> unit)) first last =
    let process_block _ blk =
      let block_overlaps = not ((blk#last < first) || (blk#first > last)) in
      if block_overlaps then (
        (* Get first address *)
        let first_addr =
          if (first < blk#first)
            then blk#first
            else first
        in
        (* Get last address *)
        let last_addr =
          if (last > blk#last)
            then blk#last
            else last
        in
        (* Get file position to start reading *)
        let first_pos =
          let offset = Int64.sub first_addr blk#first in
          Int64.add blk#file_pos offset
        in
        (* Get size to read *)
        let size=
          Int64.to_int (Int64.succ (Int64.sub last_addr first_addr))
        in
        (* Position file pointer *)
        let () = LargeFile.seek_in _rawchannel first_pos in
        (* Read data as string *)
        let blk_str = IO.nread _iochannel size in
        (* Process each byte in the string, applying the function *)
        let process_char idx c =
          let addr = Int64.add first_addr idx in
          f addr c;
          Int64.succ idx
        in
        ignore(String.fold_left process_char 0L blk_str)
      )
    in
    BlockMap.iter process_block _block_map

  (* Apply given function to all bytes present in state file.*)
  method iter (f : (Libasmir.address_t -> char -> unit)) =
    self#iter_range f 0L Int64.max_int


  (* Write values of range into given IO output channel
     Missing values in state file are filled with fill_char *)
  method write_range ?(fill_char=(Char.chr 0x90)) oc first last =
    let output_gap gap_size = 
      if (gap_size < Sys.max_string_length) then (
        if (gap_size > 0) then (
          let gap_str = String.make gap_size fill_char in
          output_string oc gap_str
        )
      )
      else (
        let err_str =
          Printf.sprintf "Could not fill gap of size: %d\n" gap_size
        in
        failwith err_str
      )
    in
    let process_block _ blk (cnt,last_addr_in_range) =
      let block_overlaps = not ((blk#last < first) || (blk#first > last)) in
      if block_overlaps then (
        let block_is_consecutive = 
          (blk#first = Int64.succ last_addr_in_range)
        in
        (* If there was a gap, fill it *)
        let front_gap_size = 
          if block_is_consecutive then 0
          else (
            (* First block in range, check if we are missing stuff *)
            if (last_addr_in_range = 0L) then (
              if (first < blk#first) 
                then Int64.to_int (Int64.sub blk#first first)
                else 0
            )
            (* Not first block in range, we are missing for sure *)
            else (
              Int64.to_int (Int64.sub blk#first (Int64.succ last_addr_in_range))
            )
          )
        in
        (* Write front gap *)
        output_gap front_gap_size;
        (* Get first address *)
        let first_addr =
          if (first < blk#first)
            then blk#first
            else first
        in
        (* Get last address *)
        let last_addr =
          if (last > blk#last) 
            then blk#last
            else last
        in
        (* Get file position to start reading *)
        let first_pos =
          let offset = Int64.sub first_addr blk#first in
          Int64.add blk#file_pos offset
        in
        (* Get size to read *)
        let size =
          Int64.to_int (Int64.succ (Int64.sub last_addr first_addr))
        in
        (* Position file pointer *)
        let () = LargeFile.seek_in _rawchannel first_pos in
        (* Read data as string *)
        let blk_str = IO.nread _iochannel size in
        (* Output string *)
        output_string oc blk_str;
        (cnt + front_gap_size + size), last_addr
      )
      else cnt,last_addr_in_range
    in
    let (cnt,_) = BlockMap.fold process_block _block_map (0,0L) in
    let back_gap_size = 
      (Int64.to_int (Int64.succ (Int64.sub last first))) - cnt 
    in
    (* Write back gap *)
    output_gap back_gap_size


end

(* =========== COMMON FUNCTIONS  ======================= *)

(* Get list of pages that comprise a range *)
let get_page_list ?(page_size=default_page_size) first last =
  let first_page = page_start first in
  let rec add_page acc curr_start =
    let next_page = Int64.add curr_start page_size in
    if (next_page > last) then List.rev acc
    else add_page (next_page :: acc) next_page
  in
  add_page [first_page] first_page

(* Count number of bits set in a int64 *)
let hamming_weight64 mask64 = 
  let rec count_bits_rec count idx = 
    if (idx >= 64) then count
    else (
      let bitmask = Int64.shift_left Int64.one idx in
      let count = 
	if ((Int64.logand bitmask mask64) <> 0L) 
	  then count + 1
	  else count
      in
      count_bits_rec count (idx+1)
    )
  in
  count_bits_rec 0 0

(* Unserialized register information *)
let unserialize_state_registers io = 
  let ebx = IO.read_real_i32 io in
  let ecx = IO.read_real_i32 io in
  let edx = IO.read_real_i32 io in
  let esi = IO.read_real_i32 io in
  let edi = IO.read_real_i32 io in
  let ebp = IO.read_real_i32 io in
  let eax = IO.read_real_i32 io in 
  let xds = IO.read_real_i32 io in
  let xes = IO.read_real_i32 io in
  let xfs = IO.read_real_i32 io in
  let xgs = IO.read_real_i32 io in
  let _ = IO.read_real_i32 io in (* orig_eax not in user_regs *)
  let eip = IO.read_real_i32 io in
  let xcs = IO.read_real_i32 io in
  let eflags = IO.read_real_i32 io in
  let esp = IO.read_real_i32 io in
  let xss = IO.read_real_i32 io in
  { 
    eax = eax; ebx = ebx; ecx = ecx; edx = edx;
    esi = esi; edi = edi; ebp = ebp; esp = esp;
    eip = eip; eflags = eflags; xcs = xcs; xds = xds;
    xes = xes; xfs = xfs; xgs = xgs; xss = xss; 
  }

(* Serialize register information *)
let serialize_state_registers io regs =
  IO.write_real_i32 io regs.ebx;
  IO.write_real_i32 io regs.ecx;
  IO.write_real_i32 io regs.edx;
  IO.write_real_i32 io regs.esi;
  IO.write_real_i32 io regs.edi;
  IO.write_real_i32 io regs.ebp;
  IO.write_real_i32 io regs.eax;
  IO.write_real_i32 io regs.xds;
  IO.write_real_i32 io regs.xes;
  IO.write_real_i32 io regs.xfs;
  IO.write_real_i32 io regs.xgs;
  IO.write_i32 io 0;
  IO.write_real_i32 io regs.eip;
  IO.write_real_i32 io regs.xcs;
  IO.write_real_i32 io regs.eflags;
  IO.write_real_i32 io regs.esp;
  IO.write_real_i32 io regs.xss

let rec read_list acc f n =
  match n with
    | 0 -> acc
    | _ -> read_list ((f ()) :: acc) f (n-1)

(* =========== BEGIN: Memblock version 40  ======================= *)
class memblock_v40 =
object (self)
  inherit memblock
  val mutable _first : int64 = 0L
  val mutable _last : int64 = 0L
  val mutable _size : int = 0
  val mutable _pos : int64 = 0L
  val mutable _taint_l : taint_region_t list = []

  (* Interface methods *)
  method first = _first
  method last = _last
  method size = _size
  method file_pos = _pos
  method taint_l = _taint_l
  method taint_block_size = 64
  method num_taint_blocks = 64

  method num_tainted_bytes = 
    List.fold_left (fun c tb -> c + (hamming_weight64 tb.tr_taintmask))
      0 _taint_l

  (* Unserialize a memory block from the input channel *)
  method unserialize flags ic io = 
    let first = int64_of_uint32 (IO.read_real_i32 io) in
    let last = int64_of_uint32 (IO.read_real_i32 io) in
    let pos = LargeFile.pos_in ic in
    let blocksize = Int64.succ (Int64.sub last first) in
    (* Move to end of page data *)
    let taint_start_pos = Int64.add pos blocksize in
    let () = LargeFile.seek_in ic taint_start_pos in
    (* Move to the end of the taint data *)
    let taint_l =
      if flags.includes_taint
        then assert(false)
        else []
    in
      _first <- first;
      _last <- last;
      _size <- Int64.to_int blocksize;
      _pos <- pos;
      _taint_l <- List.rev taint_l

  (* Serialize a memory block to the output channel *)
  method serialize ioc data = 
    let blocksize = Int64.succ (Int64.sub _last _first) in
    let data_size = Int64.of_int (String.length data) in
    assert (blocksize = data_size);
    IO.write_real_i32 ioc (Int64.to_int32 _first);
    IO.write_real_i32 ioc (Int64.to_int32 _last);
    IO.nwrite ioc data;
    (* TODO: serialize taint *)
end

(* =========== BEGIN: Memblock version 30  ======================= *)
class memblock_v30 =
object (self)
  inherit memblock
  val mutable _first : int64 = 0L
  val mutable _last : int64 = 0L
  val mutable _size : int = 0
  val mutable _pos : int64 = 0L
  val mutable _taint_l : taint_region_t list = []

  (* Interface methods *)
  method first = _first
  method last = _last
  method size = _size
  method file_pos = _pos
  method taint_l = _taint_l
  method taint_block_size = 64
  method num_taint_blocks = 64

  method num_tainted_bytes = 
    List.fold_left (fun c tb -> c + (hamming_weight64 tb.tr_taintmask))
      0 _taint_l

  (* Unserialize a memory block from the input channel *)
  method unserialize flags ic io = 
    let first = int64_of_uint32 (IO.read_real_i32 io) in
    let last = int64_of_uint32 (IO.read_real_i32 io) in
    let pos = LargeFile.pos_in ic in
    let blocksize = Int64.succ (Int64.sub last first) in
    (* Move to end of page data *)
    let taint_start_pos = Int64.add pos blocksize in
    let () = LargeFile.seek_in ic taint_start_pos in
    (* Move to the end of the taint data *)
    let taint_l =
      if flags.includes_taint
        then assert(false)
        else []
    in
      _first <- first;
      _last <- last;
      _size <- Int64.to_int blocksize;
      _pos <- pos;
      _taint_l <- List.rev taint_l

  (* Serialize a memory block to the output channel *)
  method serialize ioc data =
    let blocksize = Int64.succ (Int64.sub _last _first) in
    let data_size = Int64.of_int (String.length data) in
    assert (blocksize = data_size);
    IO.write_real_i32 ioc (Int64.to_int32 _first);
    IO.write_real_i32 ioc (Int64.to_int32 _last);
    IO.nwrite ioc data;
    (* TODO: serialize taint *)

end

(* =========== BEGIN: Memblock version 20  ======================= *)
class memblock_v20 =
object (self)
  inherit memblock
  val mutable _first : int64 = 0L
  val mutable _last : int64 = 0L
  val mutable _size : int = 0
  val mutable _pos : int64 = 0L

  (* Interface methods *)
  method first = _first
  method last = _last
  method size = _size
  method file_pos = _pos
  method taint_l = []
  method taint_block_size = 0
  method num_taint_blocks = 0
  method num_tainted_bytes = 0

  (* Unserialize a memory block from the input channel *)
  method unserialize flags ic io = 
    let first = Int64.logand 0xffffffffL
      (Int64.of_int32 (IO.read_real_i32 io)) in
    let last = Int64.logand 0xffffffffL
      (Int64.of_int32 (IO.read_real_i32 io)) in
    let pos = LargeFile.pos_in ic in
    let blocksize = Int64.succ (Int64.sub last first) in
    let () = LargeFile.seek_in ic (Int64.add pos blocksize) in
      _first <- first;
      _last <- last;
      _size <- Int64.to_int blocksize;
      _pos <- pos;

  (* Serialize a memory block to the output channel *)
  method serialize io data =
    let blocksize = Int64.succ (Int64.sub _last _first) in
    let data_size = Int64.of_int (String.length data) in
    assert (blocksize = data_size);
    IO.write_real_i32 io (Int64.to_int32 _first);
    IO.write_real_i32 io (Int64.to_int32 _last);
    IO.nwrite io data

end

(* =========== BEGIN: Memblock version 10  ======================= *)
class memblock_v10 =
object (self)
  inherit memblock
  val mutable _first : int64 = 0L
  val mutable _last : int64 = 0L
  val mutable _size : int = 0
  val mutable _pos : int64 = 0L

  (* Interface methods *)
  method first = _first
  method last = _last
  method size = _size
  method file_pos = _pos
  method taint_l = []
  method taint_block_size = 0
  method num_taint_blocks = 0
  method num_tainted_bytes = 0

  (* Unserialize a memory block from the input channel *)
  method unserialize flags ic io = 
    let first = Int64.of_int32 (IO.read_real_i32 io) in
    let last = Int64.pred (Int64.of_int32 (IO.read_real_i32 io)) in
    let pos = LargeFile.pos_in ic in
    let blocksize = Int64.succ (Int64.sub last first) in
    let () = LargeFile.seek_in ic (Int64.add pos blocksize) in
      _first <- first;
      _last <- last;
      _size <- Int64.to_int blocksize;
      _pos <- pos;

  (* Serialize a memory block to the output channel *)
  method serialize io data =
    let blocksize = Int64.succ (Int64.sub _last _first) in
    let data_size = Int64.of_int (String.length data) in
    assert (blocksize = data_size);
    IO.write_real_i32 io (Int64.to_int32 _first);
    IO.write_real_i32 io (Int64.to_int32 _last);
    IO.nwrite io data

end

(* Read list of blocks *)
let read_blocks header ic io =
  let read_block ic io = 
    match header.state_version with
      | 10 -> (
          let memblock = new memblock_v10 in
          memblock#unserialize header.state_flags ic io;
          (memblock : memblock_v10 :> memblock)
        )
      | 20 -> (
          let memblock = new memblock_v20 in
          memblock#unserialize header.state_flags ic io;
          (memblock : memblock_v20 :> memblock)
        )
      | 30 -> (
          let memblock = new memblock_v30 in
          memblock#unserialize header.state_flags ic io;
          (memblock : memblock_v30 :> memblock)
        )
      | 40 -> (
          let memblock = new memblock_v40 in
          memblock#unserialize header.state_flags ic io;
          (memblock : memblock_v40 :> memblock)
        )
      | _ -> raise Unknown_state_version
  in
  let rec read_all_blocks io =
    try
      let blk = read_block ic io in
        blk :: read_all_blocks io
    with
        IO.No_more_input
      | End_of_file -> []
  in
    read_all_blocks io


(* Read the state file header *)
let unserialize_state_header ic ioc = 
  let version = 
    let magic = IO.read_real_i32 ioc in
    if (magic = sMAGIC_NUMBER) then IO.read_i32 ioc
    else 
      let () = seek_in ic 0 in
      10
  in
  let word_size = 
    match version with
      | 10 
      | 20 -> 32
      | _ -> IO.read_ui16 ioc
  in
  let flags = 
    match version with
      | 10 
      | 20 -> 
          {
            includes_registers = true;
            includes_kernel_mem = false; (* This is not correct *)
            includes_taint = false;
            virtual_addresses = true;
            process_snapshot = true;
          }
     | 30 -> (
          let flags_raw = IO.read_ui16 ioc in
          {
            includes_registers = (flags_raw land state_registers_mask) <> 0;
            includes_kernel_mem = (flags_raw land state_kernel_mem_mask) <> 0;
            includes_taint = (flags_raw land state_taint_mask) <> 0;
            virtual_addresses = true;
            process_snapshot = true;
          }
        )

      | 40 -> (
          let flags_raw = IO.read_ui16 ioc in
          {
            includes_registers = (flags_raw land state_registers_mask) <> 0;
            includes_kernel_mem = (flags_raw land state_kernel_mem_mask) <> 0;
            includes_taint = (flags_raw land state_taint_mask) <> 0;
            virtual_addresses = (flags_raw land state_virtual_addr_mask) <> 0;
            process_snapshot = 
              (flags_raw land state_process_snapshot_mask) <> 0;
          }
        )
      | _ -> raise Unknown_state_version
  in
  {
    state_version = version;
    state_word_size = word_size;
    state_flags = flags;
  }

(* Encode flags *)
let encode_flags flags = 
  let acc =  
    if flags.includes_registers 
      then state_registers_mask 
      else 0
  in
  let acc = 
    if flags.includes_kernel_mem 
      then (acc lor state_kernel_mem_mask) 
      else acc
  in
  let acc =
    if flags.includes_taint 
      then (acc lor state_taint_mask)
      else acc
  in
  let acc =
    if flags.virtual_addresses
      then (acc lor state_virtual_addr_mask)
      else acc
  in
  let acc =
    if flags.process_snapshot
      then (acc lor state_process_snapshot_mask)
      else acc
  in
  acc


(* Serialize the state file header *)
let serialize_state_header ioc header = 
  match header.state_version with
    | 10 -> ()
    | 20 -> (
        IO.write_real_i32 ioc sMAGIC_NUMBER;
        IO.write_i32 ioc header.state_version;
      )
    | 30 | 40 -> (
        IO.write_real_i32 ioc sMAGIC_NUMBER;
        IO.write_i32 ioc header.state_version;
        IO.write_i16 ioc header.state_word_size;
        IO.write_i16 ioc (encode_flags header.state_flags);
      )
    | _ -> raise Unknown_state_version


(* Open state file and obtain state interface 
   Raises: Unknown_state_version *)
let open_state filename =
  let ic = open_in filename in
  let io = IO.input_channel ic in
  (* Read header *)
  let header = unserialize_state_header ic io in
  (* print_header stdout header; *)
  (* Process different versions *)
  match header.state_version with
    | 10 | 20 | 30 | 40 ->
        (* Read registers *)
        let regs_opt = 
          if header.state_flags.includes_registers 
            then Some(unserialize_state_registers io)
            else None
        in
        (* Read blocks in file *)
        let blocks = read_blocks header ic io in
        (* Create interface *)
        new state_interface header ic io regs_opt blocks
    | _ ->
       raise Unknown_state_version
  (* File pointer will be at end of file after this *)


(* Close state file *)
let close_state state_iface =
  state_iface#cleanup


(* Add initializers for given memory region to given program *)
let add_range_inits_to_prog prog ranges memvar state_iface =
  let (dl,sl) = prog in 
  let mem_inits = state_iface#range_inits ranges memvar in
  (dl, Block([],mem_inits)::sl)

(* Generate range inits for given range *)
let generate_range_inits filename ranges memvar =
  let sif = open_state filename in
  let inits_l = sif#range_inits ranges memvar in
  let () = close_state sif in
  inits_l

(* Print flags *)
let print_flags oc flags = 
   let type_str = 
    if flags.process_snapshot 
      then "process"
      else "system"
  in
  let addr_str = 
    if flags.virtual_addresses
      then "virtual"
      else "physical"
  in
  Printf.fprintf oc "Flags:\n\tSnapshotType: %s\n\tAddrType: %s\n" 
    type_str addr_str;
  Printf.fprintf oc 
    "\tIncludesRegisters: %b\n\tIncludesKernelMemory: %b\n\tIncludesTaint: %b\n"
    flags.includes_registers flags.includes_kernel_mem flags.includes_taint
 
(* Print header *)
let print_header oc header = 
  Printf.fprintf oc "Version: %d\n" header.state_version;
  Printf.fprintf oc "WordSize: %d\n" header.state_word_size;
  print_flags oc header.state_flags

(* Print registers *)
let print_regs oc regs = 
  Printf.fprintf oc "EAX: 0x%08lx\n" regs.eax;
  Printf.fprintf oc "EBX: 0x%08lx\n" regs.ebx;
  Printf.fprintf oc "ECX: 0x%08lx\n" regs.ecx;
  Printf.fprintf oc "EDX: 0x%08lx\n" regs.edx;
  Printf.fprintf oc "ESI: 0x%08lx\n" regs.esi;
  Printf.fprintf oc "EDI: 0x%08lx\n" regs.edi;
  Printf.fprintf oc "EBP: 0x%08lx\n" regs.ebp;
  Printf.fprintf oc "ESP: 0x%08lx\n" regs.esp;
  Printf.fprintf oc "EIP: 0x%08lx\n" regs.eip;
  Printf.fprintf oc "EFLAGS: 0x%08lx\n" regs.eflags;
  Printf.fprintf oc "CS: 0x%04lx\n" regs.xcs;
  Printf.fprintf oc "DS: 0x%04lx\n" regs.xds;
  Printf.fprintf oc "ES: 0x%04lx\n" regs.xes;
  Printf.fprintf oc "FS: 0x%04lx\n" regs.xfs;
  Printf.fprintf oc "GS: 0x%04lx\n" regs.xgs;
  Printf.fprintf oc "SS: 0x%04lx\n" regs.xss;
  flush oc

(* Print block *)
let print_block ?(print_taint=false) ?(print_pos=false) oc block = 
  let pos_str = 
    if print_pos 
      then Printf.sprintf " (%Ld)" block#file_pos
      else ""
  in
  let taint_str =
    if print_taint
    then (
      let tb_with_taint_l = 
        List.filter (fun tb -> tb.tr_taintmask <> 0L) block#taint_l
      in
      let num_tb_with_taint = List.length tb_with_taint_l in
      Printf.sprintf " (NumTB: %d TaintedBytes: %d)" 
        num_tb_with_taint block#num_tainted_bytes
    )
    else ""
  in
  Printf.fprintf oc "0x%08Lx -> 0x%08Lx%s%s\n%!" 
    block#first block#last pos_str taint_str 

