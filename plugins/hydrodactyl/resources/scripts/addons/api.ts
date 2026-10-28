import http, { httpErrorToHuman } from '@/api/http';

export { httpErrorToHuman };

/**
 * Error text from our addon endpoints. Laravel validation errors come back as
 * { message, errors: { field: [msg] } }; the DNS adapter uses Pterodactyl's
 * { errors: [{ detail }] }; port forwarding uses { error }.
 */
export const addonError = (error: unknown, fallback = 'Request failed.'): string => {
    const data = (error as { response?: { data?: Record<string, unknown> } })?.response?.data;
    if (data && typeof data === 'object') {
        if (typeof data.error === 'string') return data.error;
        const errors = data.errors;
        if (Array.isArray(errors) && errors[0] && typeof errors[0].detail === 'string') return errors[0].detail;
        if (errors && typeof errors === 'object' && !Array.isArray(errors)) {
            const first = Object.values(errors as Record<string, string[] | string>)[0];
            const message = Array.isArray(first) ? first[0] : first;
            if (message) return message;
        }
        if (typeof data.message === 'string' && data.message !== '') return data.message;
    }

    return httpErrorToHuman(error as never) || fallback;
};

export const get = <T>(url: string, params?: Record<string, unknown>) =>
    http.get<T>(url, { params }).then((r) => r.data);
export const put = <T>(url: string, body?: unknown) => http.put<T>(url, body).then((r) => r.data);
export const post = <T>(url: string, body?: unknown) => http.post<T>(url, body).then((r) => r.data);
export const patch = <T>(url: string, body?: unknown) => http.patch<T>(url, body).then((r) => r.data);
export const del = <T>(url: string, body?: unknown) => http.delete<T>(url, { data: body }).then((r) => r.data);

export const serverApi = (uuid: string, path: string) => `/api/client/servers/${uuid}${path}`;
