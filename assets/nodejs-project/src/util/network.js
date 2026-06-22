import os from 'os'

const findIPv4 = (IPInfos) => {
  return IPInfos?.find(item => item.family === 'IPv4')?.address
}

export const getIPAddress = function () {
  const interfaces = os.networkInterfaces();
  return findIPv4(interfaces['en0']) || findIPv4(interfaces['en1']) || findIPv4(interfaces['en2']) || '127.0.0.1'
}
