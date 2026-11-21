import { apiBaseUrl } from '../baseUrl';

describe('apiBaseUrl', () => {
  it('uses the address Expo loaded the app from, on the backend port', () => {
    expect(apiBaseUrl({ hostUri: '192.168.1.5:8081' })).toBe(
      'http://192.168.1.5:3000',
    );
  });

  it('lets an explicit address win and tidies it', () => {
    expect(
      apiBaseUrl({
        override: 'https://api.example.com//',
        hostUri: '192.168.1.5:8081',
      }),
    ).toBe('https://api.example.com');
  });

  it('falls back to localhost with no address or with a tunnel', () => {
    expect(apiBaseUrl({})).toBe('http://localhost:3000');
    expect(apiBaseUrl({ hostUri: 'abc-xyz.exp.direct:80' })).toBe(
      'http://localhost:3000',
    );
    expect(apiBaseUrl({ hostUri: 'abc.ngrok.io' })).toBe(
      'http://localhost:3000',
    );
  });

  it('takes another port', () => {
    expect(apiBaseUrl({ hostUri: '10.0.0.2:8081', port: 4000 })).toBe(
      'http://10.0.0.2:4000',
    );
  });
});
