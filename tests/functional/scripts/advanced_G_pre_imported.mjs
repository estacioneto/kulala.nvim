export async function getTestMjsRequestVar() {
  const test_mjs_set_request_var = "TEST_MJS_SET_REQUEST_VAR_IS_SET"

  return new Promise(resolve => {
    const checkVar = setTimeout(() => {
      resolve(test_mjs_set_request_var);
    }, 100);
  });
}
