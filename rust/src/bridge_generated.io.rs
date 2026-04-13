use super::*;
// Section: wire functions

#[no_mangle]
pub extern "C" fn wire_hello_from_rust(port_: i64) {
    wire_hello_from_rust_impl(port_)
}

#[no_mangle]
pub extern "C" fn wire_compile_typst(
    port_: i64,
    content: *mut wire_uint_8_list,
    extra_files: *mut wire_list_extra_file,
) {
    wire_compile_typst_impl(port_, content, extra_files)
}

#[no_mangle]
pub extern "C" fn wire_compile_pdf(
    port_: i64,
    content: *mut wire_uint_8_list,
    extra_files: *mut wire_list_extra_file,
) {
    wire_compile_pdf_impl(port_, content, extra_files)
}

#[no_mangle]
pub extern "C" fn wire_handle_vim_key(
    port_: i64,
    key: *mut wire_uint_8_list,
    content: *mut wire_uint_8_list,
) {
    wire_handle_vim_key_impl(port_, key, content)
}

#[no_mangle]
pub extern "C" fn wire_get_vim_mode(port_: i64) {
    wire_get_vim_mode_impl(port_)
}

#[no_mangle]
pub extern "C" fn wire_reset_vim_state(port_: i64) {
    wire_reset_vim_state_impl(port_)
}

#[no_mangle]
pub extern "C" fn wire_get_highlight_spans(port_: i64, content: *mut wire_uint_8_list) {
    wire_get_highlight_spans_impl(port_, content)
}

// Section: allocate functions

#[no_mangle]
pub extern "C" fn new_list_extra_file_0(len: i32) -> *mut wire_list_extra_file {
    let wrap = wire_list_extra_file {
        ptr: support::new_leak_vec_ptr(<wire_ExtraFile>::new_with_null_ptr(), len),
        len,
    };
    support::new_leak_box_ptr(wrap)
}

#[no_mangle]
pub extern "C" fn new_uint_8_list_0(len: i32) -> *mut wire_uint_8_list {
    let ans = wire_uint_8_list {
        ptr: support::new_leak_vec_ptr(Default::default(), len),
        len,
    };
    support::new_leak_box_ptr(ans)
}

// Section: related functions

// Section: impl Wire2Api

impl Wire2Api<String> for *mut wire_uint_8_list {
    fn wire2api(self) -> String {
        let vec: Vec<u8> = self.wire2api();
        String::from_utf8_lossy(&vec).into_owned()
    }
}
impl Wire2Api<ExtraFile> for wire_ExtraFile {
    fn wire2api(self) -> ExtraFile {
        ExtraFile {
            name: self.name.wire2api(),
            data: self.data.wire2api(),
        }
    }
}
impl Wire2Api<Vec<ExtraFile>> for *mut wire_list_extra_file {
    fn wire2api(self) -> Vec<ExtraFile> {
        let vec = unsafe {
            let wrap = support::box_from_leak_ptr(self);
            support::vec_from_leak_ptr(wrap.ptr, wrap.len)
        };
        vec.into_iter().map(Wire2Api::wire2api).collect()
    }
}

impl Wire2Api<Vec<u8>> for *mut wire_uint_8_list {
    fn wire2api(self) -> Vec<u8> {
        unsafe {
            let wrap = support::box_from_leak_ptr(self);
            support::vec_from_leak_ptr(wrap.ptr, wrap.len)
        }
    }
}
// Section: wire structs

#[repr(C)]
#[derive(Clone)]
pub struct wire_ExtraFile {
    name: *mut wire_uint_8_list,
    data: *mut wire_uint_8_list,
}

#[repr(C)]
#[derive(Clone)]
pub struct wire_list_extra_file {
    ptr: *mut wire_ExtraFile,
    len: i32,
}

#[repr(C)]
#[derive(Clone)]
pub struct wire_uint_8_list {
    ptr: *mut u8,
    len: i32,
}

// Section: impl NewWithNullPtr

pub trait NewWithNullPtr {
    fn new_with_null_ptr() -> Self;
}

impl<T> NewWithNullPtr for *mut T {
    fn new_with_null_ptr() -> Self {
        std::ptr::null_mut()
    }
}

impl NewWithNullPtr for wire_ExtraFile {
    fn new_with_null_ptr() -> Self {
        Self {
            name: core::ptr::null_mut(),
            data: core::ptr::null_mut(),
        }
    }
}

impl Default for wire_ExtraFile {
    fn default() -> Self {
        Self::new_with_null_ptr()
    }
}

// Section: sync execution mode utility

#[no_mangle]
pub extern "C" fn free_WireSyncReturn(ptr: support::WireSyncReturn) {
    unsafe {
        let _ = support::box_from_leak_ptr(ptr);
    };
}
