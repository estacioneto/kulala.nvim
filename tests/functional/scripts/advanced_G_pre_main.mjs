import { getTestMjsRequestVar } from './advanced_G_pre_imported.mjs';

request.variables.set('MJS_SET_REQUEST_VAR', await getTestMjsRequestVar());
client.log("MJS: PRE TEST");
