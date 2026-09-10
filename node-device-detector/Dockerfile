# node-device-detector(= kcloud node-agent) 멀티파일 빌드: scan/report/validate/main 등 *.go 전체 COPY.
FROM golang:1.22 as build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /detector .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /detector /detector
USER 65532
ENTRYPOINT ["/detector"]
