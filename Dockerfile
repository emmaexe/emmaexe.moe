FROM alpine:latest AS hugo-builder

RUN apk add --no-cache hugo npm git

WORKDIR /build
COPY . .

RUN git submodule update --init --recursive
RUN ln -s ./themes/hugo-material-catppuccin/package.json ./package.json
RUN npm i
RUN hugo

FROM nginx:latest AS emmaexe-moe

COPY --from=hugo-builder /build/public /app/public
RUN mkdir /app/.well-known
RUN touch /app/robots.txt
RUN chmod -R o+rX /app

COPY ./nginx.conf /etc/nginx/

EXPOSE 80
