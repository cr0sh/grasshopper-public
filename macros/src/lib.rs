use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, ItemFn};

#[proc_macro_attribute]
pub fn lua_export(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let ItemFn {
        attrs,
        vis,
        sig,
        block,
    } = parse_macro_input!(item as ItemFn);

    let new_block = quote! {
        {
            crate::rethrow::rethrow_cpp(move || #block)
        }
    };

    quote! {
        #(#attrs)*
        #[no_mangle]
        #vis #sig #new_block
    }
    .into()
}
