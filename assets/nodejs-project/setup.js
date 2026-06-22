import * as fs from 'fs';
import * as path from 'path';

const babelConfig = `
{
  "presets": [
    ["@babel/preset-env", {
      "targets": {
        "node": "18"
      }
    }]
  ],
  "plugins": [
    ["@babel/plugin-transform-runtime", {
      "regenerator": true
    }]
  ]
}
`;

const prettierConfig = `
{
  "semi": true,
  "trailingComma": "es5",
  "singleQuote": true,
  "printWidth": 100,
  "tabWidth": 2,
  "useTabs": false
}
`;

const nodemonConfig = `
{
  "watch": ["src"],
  "ext": "js,json,jsx,less",
  "ignore": ["node_modules", "dist"],
  "exec": "node src/dev.js",
  "env": {
    "NODE_ENV": "development"
  }
}
`;

fs.writeFileSync('.babelrc', babelConfig);
fs.writeFileSync('.prettierrc.json', prettierConfig);
fs.writeFileSync('nodemon.json', nodemonConfig);

console.log('✅ Configuration files created');
