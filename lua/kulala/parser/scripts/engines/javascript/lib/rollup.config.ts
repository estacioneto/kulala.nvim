import typescript from '@rollup/plugin-typescript';
import { nodeResolve } from '@rollup/plugin-node-resolve';
import terser from '@rollup/plugin-terser';

export default [
  {
    input: './src/pre_request.ts',
    output: [
      {
        file: 'dist/pre_request.js',
        format: 'cjs'
      }, {
        file: 'dist/pre_request.mjs',
        format: 'es'
      }
    ],
    plugins: [
      typescript(),
      nodeResolve(),
      terser({
        mangle: {
          reserved: [
            'client',
            'request',
          ],
        },
      }),
    ],
  },
  {
    input: './src/post_request.ts',
    output: [
      {
        file: 'dist/post_request.js',
        format: 'cjs'
      }, {
        file: 'dist/post_request.mjs',
        format: 'es'
      }
    ],
    plugins: [
      typescript(),
      nodeResolve(),
      terser({
        mangle: {
          reserved: [
            'client',
            'response',
            'request',
            'assert'
          ],
        },
      }),
    ],
  },
]
