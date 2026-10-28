# Pin esplicito (mai :latest): il tag upstream decide il protocollo push e il
# comportamento del server — un upgrade implicito ha già rotto i push (pre-v2)
# e il sync WS (CheckOrigin in v1.12.x). PR #43 (SELF_HOST_PUBLIC_IP) e #44
# (XXX currency PayPal/SimpleFIN) sono mergiate upstream e incluse qui.
FROM budgero/budgero:v1.19.5
USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]
