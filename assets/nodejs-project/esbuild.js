import * as esbuild from 'esbuild';
import fs from 'fs';
import { createHash } from 'crypto';

esbuild.build({
    entryPoints: ['src/main.js'],
    outfile: 'dist/main.js',
    bundle: true,
    minify: true,
    write: true,
    format: 'cjs',
    platform: 'node',
    target: 'node18',
    sourcemap: process.env.NODE_ENV === 'development' ? 'inline' : false,
    external: [],
    plugins: [genMd5()],
});

function genMd5() {
    return {
        name: 'gen-output-file-md5',
        setup(build) {
            build.onEnd(async (_) => {
                const md5 = createHash('md5').update(fs.readFileSync('dist/main.js')).digest('hex');
                fs.writeFileSync('dist/main.js.md5', md5);
            });
        },
    };
}
