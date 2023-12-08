const fs = require('fs');
fs.cp('../contracts', './contracts', { recursive: true }, (err) => {
  if (err) {
    console.error(err);
  }
  console.log("copy file success.");
});